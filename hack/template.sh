#!/usr/bin/env bash
# Renders the chart of every component in services/ from a checkout of weigate with the stand values
# and checks the result: kubeconform, the rules of its profile and its Application.
#   - apps/services/<c>.yaml: minimal stand (SRS 6.4), chart from git of weigate, values.yaml; with
#     values-full.yaml the overlay of the full stand is rendered and checked too.
#   - services/<c>/application.yaml: a component only of the full stand (SRS 6.2, 6.3), chart from Zot, not synced.
# Usage: CRD_SCHEMAS=<kubeconform schema location> WEIGATE_DIR=<checkout of m5tshift/weigate> hack/template.sh
# Needs helm, kubeconform and yq (mikefarah v4).
set -euo pipefail
cd "$(dirname "$0")/.."

: "${CRD_SCHEMAS:?set CRD_SCHEMAS (see Makefile)}"
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

# kubeconform with the CRD schemas (ExternalSecret, DestinationRule, VirtualService of the full stand).
validate() { kubeconform -strict -summary -schema-location default -schema-location "$CRD_SCHEMAS" "$1"; }

# Checks common to both profiles: no Secret or Namespace, the image of GHCR, OTLP export, requests and limits.
check_common() { # check_common <component> <manifest> <profile>
  local c=$1 manifest=$2 p=$3 kinds image missing
  kinds=$(yq eval-all '.kind' "$manifest" | grep -v '^---$' | sort -u)
  for k in Secret Namespace; do
    if grep -qx "$k" <<<"$kinds"; then report "$c ($p): renders $k"; fi
  done
  image=$(yq eval-all "$deploy | .spec.template.spec.containers[0].image" "$manifest")
  case "$image" in
    "ghcr.io/m5tshift/weigate/$c:"?*) ;;
    *) report "$c ($p): image '$image', want ghcr.io/m5tshift/weigate/$c:<tag>" ;;
  esac
  if ! yq eval-all "$deploy | .spec.template.spec.containers[].env[] | select(.name == \"OTEL_EXPORTER_OTLP_ENDPOINT\")" \
    "$manifest" | grep -q .; then
    report "$c ($p): no OTEL_EXPORTER_OTLP_ENDPOINT, traces do not reach the collector"
  fi
  missing=$(yq eval-all "$deploy | .spec.template.spec | (.containers[], .initContainers[]?) |
    select(.resources.requests.cpu == null or .resources.requests.memory == null or
           .resources.limits.cpu == null or .resources.limits.memory == null) | .name" "$manifest")
  [ -z "$missing" ] || report "$c ($p): no requests or limits in container $missing"
}

# Mesh resources of SRS 4.1.9: the callee carries the timeout and retries of its callers; fault injection is off.
check_istio() { # check_istio <component> <manifest> <profile>
  local c=$1 manifest=$2 p=$3 want="" got
  case "$c" in
    rate-service) want="500ms 1" ;;
    ledger-service) want="2s 1" ;;
  esac
  if [ "$(yq eval-all '[select(.kind == "VirtualService") | .spec.http[] | select(.fault != null)] | length' "$manifest")" != 0 ]; then
    report "$c ($p): VirtualService with fault injection"
  fi
  [ -n "$want" ] || return 0
  got=$(yq eval-all 'select(.kind == "VirtualService") | .spec.http[0] | [.timeout, .retries.attempts] | join(" ")' "$manifest")
  [ "$got" = "$want" ] || report "$c ($p): VirtualService timeout and retries '$got', want '$want'"
  got=$(yq eval-all 'select(.kind == "DestinationRule") | .spec.trafficPolicy.outlierDetection | has("interval")' "$manifest")
  [ "$got" = "true" ] || report "$c ($p): no DestinationRule with outlier detection"
  # rate-service answers 503 by design (SRS 4.1.3): only gateway errors may eject its pods.
  if [ "$c" = rate-service ]; then
    got=$(yq eval-all 'select(.kind == "DestinationRule") | .spec.trafficPolicy.outlierDetection |
      [.consecutive5xxErrors, .consecutiveGatewayErrors > 0] | join(" ")' "$manifest")
    [ "$got" = "0 true" ] || report "$c ($p): outlier detection must count gateway errors only, got '$got'"
  fi
}

# Full stand (SRS 6.2, 6.3): >= 2 replicas with a PDB, one replica only for the components 6.2 budgets so;
# every mounted Secret comes from an ExternalSecret.
check_full() { # check_full <component> <manifest>
  local c=$1 manifest=$2 replicas pdbs mounted es s
  replicas=$(yq eval-all "$deploy | .spec.replicas" "$manifest")
  pdbs=$(yq eval-all 'select(.kind == "PodDisruptionBudget") | .kind' "$manifest" | grep -c . || true)
  case "$c" in
    reconciliation-service | reporting-service)
      [ "$replicas" = "1" ] || report "$c (full): replicas '$replicas', SRS 6.2 budgets 1"
      [ "$pdbs" = "0" ] || report "$c (full): PDB with one replica blocks a drain" ;;
    *)
      [ "$replicas" -ge 2 ] 2>/dev/null || report "$c (full): replicas '$replicas', want at least 2"
      [ "$pdbs" = "1" ] || report "$c (full): want one PodDisruptionBudget, got $pdbs" ;;
  esac
  mounted=$(yq eval-all "$deploy | .spec.template.spec.volumes[]? | select(.secret != null) | .secret.secretName" "$manifest")
  es=$(yq eval-all 'select(.kind == "ExternalSecret") | .spec.target.name' "$manifest")
  for s in $mounted; do
    grep -qx "$s" <<<"$es" || report "$c (full): Secret $s is mounted without an ExternalSecret"
  done
}

deploy='select(.kind == "Deployment")'

for values in "${values_files[@]}"; do
  c=$(basename "$(dirname "$values")")
  chart="$weigate/charts/$c"
  app="apps/services/$c.yaml"
  full_app="services/$c/application.yaml"
  overlay="services/$c/values-full.yaml"

  if [ ! -f "$chart/Chart.yaml" ]; then report "$c: no chart $chart"; continue; fi
  helm dependency build --skip-refresh "$chart" >/dev/null

  # Components only of the full stand: an Application next to the values, not synced until m5tshift/weigate#183;
  # it takes a released version of the chart from Zot (CI of weigate bumps it, so it may lag behind Chart.yaml in git).
  if [ -f "$full_app" ]; then
    [ ! -f "$app" ] || report "$c: both $app and $full_app"
    src='select(.kind == "Application") | .spec.sources[] | select(.chart != null)'
    got=$(yq eval "$src | [.repoURL, .chart] | join(\" \")" "$full_app")
    want="zot.registry.svc:5000/weigate/charts $c"
    [ "$got" = "$want" ] || report "$c: $full_app takes '$got', want '$want'"
    rev=$(yq eval "$src | .targetRevision" "$full_app")
    [[ "$rev" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || report "$c: $full_app chart version '$rev', want a released version"
    vf=$(yq eval "$src | .helm.valueFiles | join(\" \")" "$full_app")
    want="\$values/services/$c/values.yaml"
    [ ! -f "$overlay" ] || want="$want \$values/services/$c/values-full.yaml"
    [ "$vf" = "$want" ] || report "$c: $full_app values files '$vf', want '$want'"
    ns=$(yq eval 'select(.kind == "Application") | .spec.destination.namespace' "$full_app")
    [ "$ns" = "apps" ] || report "$c: $full_app namespace is '$ns', want apps"
    validate "$full_app" || report "$c: kubeconform failed for $full_app"

    manifest="$out/$c-full.yaml"
    args=(-f "$values")
    [ ! -f "$overlay" ] || args+=(-f "$overlay")
    if ! helm template "$c" "$chart" --namespace apps "${args[@]}" >"$manifest"; then
      report "$c (full): helm template failed"; continue
    fi
    validate "$manifest" || report "$c (full): kubeconform failed"
    check_common "$c" "$manifest" full
    check_istio "$c" "$manifest" full
    check_full "$c" "$manifest"
    echo "template: $c (full) ok"
    continue
  fi

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

  manifest="$out/$c.yaml"
  if ! helm template "$c" "$chart" --namespace apps -f "$values" >"$manifest"; then
    report "$c: helm template failed"
    continue
  fi

  if ! kubeconform -strict -summary "$manifest"; then report "$c: kubeconform failed"; fi

  # Minimal stand (SRS 6.4): no VirtualService/DestinationRule, ESO, ServiceMonitor or PDB; Secrets come from the stand script.
  kinds=$(yq eval-all '.kind' "$manifest" | grep -v '^---$' | sort -u)
  for k in PodDisruptionBudget ExternalSecret VirtualService DestinationRule ServiceMonitor; do
    if grep -qx "$k" <<<"$kinds"; then report "$c: renders $k"; fi
  done

  replicas=$(yq eval-all "$deploy | .spec.replicas" "$manifest")
  [ "$replicas" = "1" ] || report "$c: replicas '$replicas', want 1"

  check_common "$c" "$manifest" minimal
  echo "template: $c ok"

  # Full stand overlay of a component of the minimal stand (values.yaml + values-full.yaml): the parts it already
  # carries; replicas, PDB and ExternalSecrets of these components come with m5tshift/weigate#183.
  if [ -f "$overlay" ]; then
    manifest="$out/$c-overlay.yaml"
    if ! helm template "$c" "$chart" --namespace apps -f "$values" -f "$overlay" >"$manifest"; then
      report "$c (full overlay): helm template failed"; continue
    fi
    validate "$manifest" || report "$c (full overlay): kubeconform failed"
    check_common "$c" "$manifest" "full overlay"
    check_istio "$c" "$manifest" "full overlay"
    echo "template: $c (full overlay) ok"
  fi
done

# Every service Application has its values.
for app in apps/services/*.yaml; do
  c=$(basename "$app" .yaml)
  [ -f "services/$c/values.yaml" ] || report "$c: Application without services/$c/values.yaml"
done

exit "$fail"
