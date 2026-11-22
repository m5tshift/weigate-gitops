#!/usr/bin/env bash
# Renders the Istio and observability charts with the values of this repository and the kustomizations of
# platform/istio/mesh and platform/observability/config, and validates the result with kubeconform.
# Chart, version and values files come from the Applications.
# Usage: hack/render.sh   (needs helm, kubectl, kubeconform and yq v4; network access to the chart repositories)
set -euo pipefail
cd "$(dirname "$0")/.."

: "${CRD_SCHEMAS:?set CRD_SCHEMAS (see Makefile)}"
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT

fail=0
check() { # check <name> <manifest>
  # CRDs are upstream artifacts without a schema in the default location; the rest is validated strictly.
  if kubeconform -strict -summary -skip CustomResourceDefinition -schema-location default -schema-location "$CRD_SCHEMAS" "$2"; then
    echo "render: $1 ok"
  else
    echo "render: $1 failed"; fail=1
  fi
}

for app in apps/platform/istio*.yaml apps/platform/observability*.yaml; do
  name=$(yq eval '.metadata.name' "$app")
  chart=$(yq eval '.spec.sources[]? | select(.chart != null) | .chart' "$app")
  [ -n "$chart" ] || continue
  repo=$(yq eval '.spec.sources[] | select(.chart != null) | .repoURL' "$app")
  version=$(yq eval '.spec.sources[] | select(.chart != null) | .targetRevision' "$app")
  release=$(yq eval '.spec.sources[] | select(.chart != null) | .helm.releaseName' "$app")
  ns=$(yq eval '.spec.destination.namespace' "$app")
  args=()
  while IFS= read -r vf; do
    [ -n "$vf" ] && args+=(-f "${vf#\$values/}")
  done < <(yq eval '.spec.sources[] | select(.chart != null) | .helm.valueFiles[]?' "$app")
  if helm template "$release" "$chart" --repo "$repo" --version "$version" --namespace "$ns" "${args[@]}" \
    >"$out/$name.yaml"; then
    check "$name" "$out/$name.yaml"
  else
    echo "render: $name: helm template failed"; fail=1
  fi
done

for dir in platform/istio/mesh platform/observability/config; do
  name=$(echo "${dir#platform/}" | tr / -)
  if kubectl kustomize "$dir" >"$out/$name.yaml"; then
    check "$name" "$out/$name.yaml"
  else
    echo "render: $name: kustomize failed"; fail=1
  fi
done

exit "$fail"
