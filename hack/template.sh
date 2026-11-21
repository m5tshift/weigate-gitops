#!/usr/bin/env bash
# Renders the chart of every component in services/ from a checkout of weigate with the stand values
# and checks the result: kubeconform, the minimal stand rules (SRS 6.4) and the Application next to it.
# Usage: WEIGATE_DIR=<checkout of m5tshift/weigate> hack/template.sh
# Needs helm, kubeconform and yq (mikefarah v4).
set -euo pipefail
cd "$(dirname "$0")/.."

weigate=${WEIGATE_DIR:-../weigate}
if [ ! -d "$weigate/charts" ]; then
  echo "template: no charts in $weigate; set WEIGATE_DIR to a checkout of m5tshift/weigate" >&2
  exit 1
fi

out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT

fail=0
report() { echo "template: $1"; fail=1; }

shopt -s nullglob
values_files=(services/*/values.yaml)
if [ "${#values_files[@]}" -eq 0 ]; then
  echo "template: no services/*/values.yaml"
  exit 0
fi

for values in "${values_files[@]}"; do
  c=$(basename "$(dirname "$values")")
  chart="$weigate/charts/$c"
  app="apps/services/$c.yaml"
  manifest="$out/$c.yaml"

  if [ ! -f "$chart/Chart.yaml" ]; then report "$c: no chart $chart"; continue; fi

  # The Application must take this chart from git of weigate with this values file.
  if [ ! -f "$app" ]; then
    report "$c: no Application $app"
  else
    path=$(yq eval 'select(.kind == "Application") | .spec.sources[] | select(.repoURL == "https://github.com/m5tshift/weigate") | .path' "$app")
    vf=$(yq eval 'select(.kind == "Application") | .spec.sources[].helm.valueFiles[]' "$app")
    ns=$(yq eval 'select(.kind == "Application") | .spec.destination.namespace' "$app")
    [ "$path" = "charts/$c" ] || report "$c: Application chart path is '$path', want charts/$c"
    [ "$vf" = "\$values/services/$c/values.yaml" ] || report "$c: Application values file is '$vf'"
    [ "$ns" = "apps" ] || report "$c: Application namespace is '$ns', want apps"
  fi

  helm dependency build --skip-refresh "$chart" >/dev/null
  if ! helm template "$c" "$chart" --namespace apps -f "$values" >"$manifest"; then
    report "$c: helm template failed"
    continue
  fi

  if ! kubeconform -strict -summary "$manifest"; then report "$c: kubeconform failed"; fi

  # Minimal stand (SRS 6.4): no Istio, ESO, ServiceMonitor or PDB; Secrets come from the stand script.
  kinds=$(yq eval-all '.kind' "$manifest" | grep -v '^---$' | sort -u)
  for k in PodDisruptionBudget ExternalSecret VirtualService DestinationRule ServiceMonitor Secret Namespace; do
    if grep -qx "$k" <<<"$kinds"; then report "$c: renders $k"; fi
  done

  deploy='select(.kind == "Deployment")'
  replicas=$(yq eval-all "$deploy | .spec.replicas" "$manifest")
  [ "$replicas" = "1" ] || report "$c: replicas '$replicas', want 1"

  image=$(yq eval-all "$deploy | .spec.template.spec.containers[0].image" "$manifest")
  case "$image" in
    "ghcr.io/m5tshift/weigate/$c:"?*) ;;
    *) report "$c: image '$image', want ghcr.io/m5tshift/weigate/$c:<tag>" ;;
  esac

  if yq eval-all "$deploy | .spec.template.spec.containers[].env[] | select(.name == \"OTEL_EXPORTER_OTLP_ENDPOINT\")" \
    "$manifest" | grep -q .; then
    report "$c: OTLP export is on"
  fi

  missing=$(yq eval-all "$deploy | .spec.template.spec | (.containers[], .initContainers[]?) |
    select(.resources.requests.cpu == null or .resources.requests.memory == null or
           .resources.limits.cpu == null or .resources.limits.memory == null) | .name" "$manifest")
  [ -z "$missing" ] || report "$c: no requests or limits in container $missing"

  echo "template: $c ok"
done

# Every service Application has its values.
for app in apps/services/*.yaml; do
  c=$(basename "$app" .yaml)
  [ -f "services/$c/values.yaml" ] || report "$c: Application without services/$c/values.yaml"
done

exit "$fail"
