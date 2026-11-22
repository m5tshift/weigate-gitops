#!/usr/bin/env bash
# Checks the vmalert rules of platform/observability/vmalert/values.yaml with vmalert -dryRun.
# Usage: hack/alerts.sh   (needs yq v4 and vmalert in PATH)
set -euo pipefail
cd "$(dirname "$0")/.."
rules=$(mktemp --suffix=.yaml 2>/dev/null || mktemp)
trap 'rm -f "$rules"' EXIT
yq eval '.server.config.alerts' platform/observability/vmalert/values.yaml >"$rules"
vmalert -dryRun -rule="$rules"
