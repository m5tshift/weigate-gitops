#!/usr/bin/env bash
# Checks the Grafana dashboards of platform/observability/config/dashboards (SRS 4.5.3): every file is valid JSON,
# and every metric of the panel queries exists. Metric selectors are written with braces (metric{...}).
# - weigate_*, http_server_*, outbox_*: an OTel instrument of the Go code of weigate, created directly or through a
#   local gauge("name", ...) helper (dots become underscores;
#   _bucket/_sum/_count, _total and the unit suffix _seconds are added by the Prometheus translation).
# - other metrics: a known exporter prefix (Strimzi, Istio/Envoy, kube-state-metrics, kubelet, Hubble, Tempo).
# Usage: WEIGATE_DIR=../weigate hack/dashboards.sh   (needs jq)
set -euo pipefail
cd "$(dirname "$0")/.."

: "${WEIGATE_DIR:?set WEIGATE_DIR to a checkout of weigate}"
dir=platform/observability/config/dashboards

instruments=$(grep -rhoE --include='*.go' --exclude='*_test.go' \
  '((Int64|Float64)(Observable)?(Counter|UpDownCounter|Histogram|Gauge)|gauge)\("[^"]+"' "$WEIGATE_DIR/pkg" "$WEIGATE_DIR/services" |
  sed -E 's/.*\("([^"]+)"/\1/; s/\./_/g' | sort -u)
[ -n "$instruments" ] || { echo "dashboards: no instruments found in $WEIGATE_DIR"; exit 1; }

known() { # known <metric>
  local a b c
  for a in "$1" "${1%_bucket}" "${1%_sum}" "${1%_count}"; do
    for b in "$a" "${a%_total}"; do
      for c in "$b" "${b%_seconds}"; do
        grep -qxF "$c" <<<"$instruments" && return 0
      done
    done
  done
  return 1
}

fail=0
for f in "$dir"/*.json; do
  if ! jq empty "$f"; then
    echo "dashboards: $f: invalid JSON"; fail=1; continue
  fi
  metrics=$(jq -r '.panels[].targets[] | select(.expr != null) | .expr' "$f" | grep -oE '[a-zA-Z_:][a-zA-Z0-9_:]*\{' | tr -d '{' | sort -u || true)
  trace_queries=$(jq -r '.panels[].targets[] | select(.query != null) | .query' "$f" || true)
  if [ -z "$metrics" ] && [ -z "$trace_queries" ]; then
    echo "dashboards: $f: no metrics or trace queries"; fail=1
  fi
  for m in $metrics; do
    case "$m" in
      weigate_* | http_server_* | outbox_*)
        known "$m" || { echo "dashboards: $f: $m is not a metric of weigate"; fail=1; } ;;
      kafka_* | envoy_* | istio_* | kube_* | kubelet_* | hubble_* | tempo_*) ;;
      *) echo "dashboards: $f: $m has no known source"; fail=1 ;;
    esac
  done
done
[ "$fail" -eq 0 ] && echo "dashboards: $(ls "$dir"/*.json | wc -l | tr -d ' ') files ok"
exit "$fail"
