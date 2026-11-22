#!/usr/bin/env bash
# Renders the Istio and observability charts with the values of this repository and the kustomizations of
# platform/istio/mesh, platform/observability/config and both CNPG and both MongoDB profiles, platform/clickhouse/full, the operator chart of platform/clickhouse, and validates the result with kubeconform.
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

for dir in platform/istio/mesh platform/observability/config platform/cnpg/clusters platform/cnpg/full \
  platform/percona-mongodb/cluster platform/percona-mongodb/full platform/clickhouse/full; do
  name=$(echo "${dir#platform/}" | tr / -)
  if kubectl kustomize "$dir" >"$out/$name.yaml"; then
    check "$name" "$out/$name.yaml"
  else
    echo "render: $name: kustomize failed"; fail=1
  fi
done

# CNPG profiles: the minimal stand has 1 instance and no backups (SRS 6.4); the full one has 3 clusters with 2 instances,
# Barman Cloud with retention 7d and a ScheduledBackup each (SRS 4.1.6).
clusters() { yq -N 'select(.kind == "Cluster") | [.metadata.name, .spec.instances, .spec.backup.retentionPolicy // "none"] | join(" ")' "$1" | sed '/^$/d'; }
bad=$(clusters "$out/cnpg-clusters.yaml" | grep -v ' 1 none$' || true)
[ -z "$bad" ] || { echo "render: cnpg-clusters: want 1 instance and no backup: $bad"; fail=1; }
full=$(clusters "$out/cnpg-full.yaml")
[ "$(grep -c ' 2 7d$' <<<"$full")" = 3 ] && [ "$(wc -l <<<"$full")" -eq 3 ] \
  || { echo "render: cnpg-full: want 3 clusters with 2 instances and backup 7d: $full"; fail=1; }
backups=$(yq -N 'select(.kind == "ScheduledBackup") | .spec.cluster.name' "$out/cnpg-full.yaml" | sed '/^$/d' | sort | tr '\n' ' ')
[ "$backups" = "invoice-pg ledger-pg merchant-pg " ] || { echo "render: cnpg-full: ScheduledBackup for '$backups'"; fail=1; }

# MongoDB profiles: the minimal stand has 1 member, no backups and one user (SRS 6.4); the full one has 3 members of 768Mi,
# PBM daily at 03:00 with keep 7 and three users (SRS 4.1.6, 6.2).
mongo() { yq -N 'select(.kind == "PerconaServerMongoDB") | '"$2" "$1" | sed '/^$/d'; }
got=$(mongo "$out/percona-mongodb-cluster.yaml" '[.spec.replsets[0].size, .spec.backup.enabled, (.spec.users | length)] | join(" ")')
[ "$got" = "1 false 1" ] || { echo "render: percona-mongodb-cluster: want '1 false 1': $got"; fail=1; }
got=$(mongo "$out/percona-mongodb-full.yaml" '[.spec.replsets[0].size, .spec.replsets[0].resources.limits.memory, .spec.backup.enabled, .spec.backup.tasks[0].schedule, .spec.backup.tasks[0].keep, .spec.backup.tasks[0].storageName, .spec.backup.storages.garage.s3.bucket, (.spec.users | map(.name) | join(","))] | join(" ")')
[ "$got" = "3 768Mi true 0 3 * * * 7 garage mongo-backups chain-watcher,webhook-service,reconciliation-service" ] \
  || { echo "render: percona-mongodb-full: unexpected profile: $got"; fail=1; }

# ClickHouse: no Application reads platform/clickhouse yet (SRS 6.4), so the operator chart is rendered from its values with the
# version named in the header of values.yaml. The full profile has one shard, one replica, requests and limits, no Secret (SRS 4.1.6).
ch_version=$(sed -n 's/^# Altinity Operator for ClickHouse, chart altinity-clickhouse-operator \([0-9.]*\) .*/\1/p' platform/clickhouse/operator/values.yaml)
if [ -n "$ch_version" ] && helm template clickhouse-operator altinity-clickhouse-operator --repo https://helm.altinity.com \
  --version "$ch_version" --namespace data -f platform/clickhouse/operator/values.yaml >"$out/clickhouse-operator.yaml"; then
  check clickhouse-operator "$out/clickhouse-operator.yaml"
  noresources=$(yq -N 'select(.kind == "Deployment" or .kind == "Job") | .spec.template.spec.containers[] | select(.resources.limits.memory == null or .resources.requests.memory == null) | .name' "$out/clickhouse-operator.yaml" | sed '/^$/d')
  [ -z "$noresources" ] || { echo "render: clickhouse-operator: no requests or limits: $noresources"; fail=1; }
else
  echo "render: clickhouse-operator: helm template failed (version '$ch_version')"; fail=1
fi
got=$(yq -N 'select(.kind == "ClickHouseInstallation") | [.spec.configuration.clusters[0].layout.shardsCount, .spec.configuration.clusters[0].layout.replicasCount] | join(" ")' "$out/clickhouse-full.yaml" | sed '/^$/d')
[ "$got" = "1 1" ] || { echo "render: clickhouse-full: want '1 1' shards and replicas: $got"; fail=1; }
bad=$(yq -N 'select(.kind == "ClickHouseInstallation") | .spec.templates.podTemplates[].spec.containers[] | select(.resources.limits.memory == null or .resources.requests.memory == null) | .name' "$out/clickhouse-full.yaml" | sed '/^$/d')
[ -z "$bad" ] || { echo "render: clickhouse-full: no requests or limits: $bad"; fail=1; }
[ "$(yq -N 'select(.kind == "Secret") | .kind' "$out/clickhouse-full.yaml" | sed '/^$/d' | wc -l)" -eq 0 ] || { echo "render: clickhouse-full: Secret in the profile"; fail=1; }
ddl=$(yq -N 'select(.kind == "ConfigMap") | .data | keys | join(" ")' "$out/clickhouse-full.yaml" | sed '/^$/d')
[ "$ddl" = "01-database.sql 02-invoice-events.sql 03-chain-transfers.sql 04-rate-ticks.sql 05-reports.sql" ] || { echo "render: clickhouse-full: ddl files: $ddl"; fail=1; }

exit "$fail"
