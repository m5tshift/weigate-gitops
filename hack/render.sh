#!/usr/bin/env bash
# Renders the Karpenter and KWOK charts, the ARC charts and kustomization (platform/arc), the Istio and observability charts with the values of this repository and the kustomizations of
# platform/istio/mesh, platform/observability/config and both CNPG and both MongoDB profiles, platform/clickhouse/full, platform/network-policies/policies, the operator chart of platform/clickhouse, and validates the result with kubeconform.
# Chart, version and values files come from the Applications.
# Usage: hack/render.sh   (needs helm, kubectl, kubeconform and yq v4; network access to the chart repositories)
set -euo pipefail
cd "$(dirname "$0")/.."

: "${CRD_SCHEMAS:?set CRD_SCHEMAS (see Makefile)}"
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT

fail=0
check() { # check <name> <manifest>
  # CRDs are upstream artifacts without a schema in the default location, KWOKNodeClass and Stage (KWOK) have none in the catalog; the rest is validated strictly.
  if kubeconform -strict -summary -skip CustomResourceDefinition,KWOKNodeClass,Stage -schema-location default -schema-location "$CRD_SCHEMAS" "$2"; then
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
  platform/percona-mongodb/cluster platform/percona-mongodb/full platform/clickhouse/full \
  platform/network-policies/policies platform/karpenter/config; do
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

# ClickHouse: operator chart is rendered from apps/platform/clickhouse-operator.yaml.
# The full profile has one shard, one replica, requests and limits, no Secret (SRS 4.1.6).
ch_version=$(yq eval '.spec.sources[] | select(.chart != null) | .targetRevision' apps/platform/clickhouse-operator.yaml)
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

# ARC: both charts are rendered from the Applications in apps/platform (OCI chart, version, values).
# Runners start from zero, are limited, have requests and limits, no Secret, no privileged container;
# the runner network policy allows exactly the hosts of SRS 4.1.11 (plus *.blob.core.windows.net and get.helm.sh).
for app in apps/platform/arc-controller.yaml apps/platform/arc-runners.yaml; do
  name=$(yq eval '.metadata.name' "$app")
  chart=$(yq eval '.spec.sources[] | select(.chart != null) | .chart' "$app")
  repo=$(yq eval '.spec.sources[] | select(.chart != null) | .repoURL' "$app")
  version=$(yq eval '.spec.sources[] | select(.chart != null) | .targetRevision' "$app")
  vf=$(yq eval '.spec.sources[] | select(.chart != null) | .helm.valueFiles[0]' "$app")
  if helm template "$name" "oci://$repo/$chart" --version "$version" --namespace ci -f "${vf#\$values/}" >"$out/$name.yaml"; then
    check "$name" "$out/$name.yaml"
  else
    echo "render: $name: helm template failed"; fail=1
  fi
done
kubectl kustomize platform/arc/config >"$out/arc-config.yaml" && check arc-config "$out/arc-config.yaml" \
  || { echo "render: arc-config: kustomize failed"; fail=1; }
for f in arc-controller arc-runners; do
  bad=$(yq -N 'select(.kind == "Deployment" or .kind == "AutoscalingRunnerSet") | (.spec.template.spec.containers[], .spec.listenerTemplate.spec.containers[]?) | select(.resources.limits.memory == null or .resources.requests.memory == null) | .name' "$out/$f.yaml" | sed '/^$/d')
  [ -z "$bad" ] || { echo "render: $f: no requests or limits: $bad"; fail=1; }
done
got=$(yq -N 'select(.kind == "AutoscalingRunnerSet") | [.spec.minRunners, .spec.maxRunners] | join(" ")' "$out/arc-runners.yaml" | sed '/^$/d')
[ "$got" = "0 2" ] || { echo "render: arc-runners: want minRunners 0 and maxRunners 2: $got"; fail=1; }
got=$(yq -N 'select(.kind == "AutoscalingRunnerSet") | .spec.template.spec.containers[].name' "$out/arc-runners.yaml" | sed '/^$/d' | tr '\n' ' ')
[ "$got" = "runner buildkitd " ] || { echo "render: arc-runners: containers '$got'"; fail=1; }
bad=$(yq -N 'select(.kind == "AutoscalingRunnerSet") | .spec.template.spec.containers[] | select(.securityContext.privileged == true or .securityContext.allowPrivilegeEscalation != false) | .name' "$out/arc-runners.yaml" | sed '/^$/d')
[ -z "$bad" ] || { echo "render: arc-runners: privileged or privilege escalation: $bad"; fail=1; }
grep -q 'buildkit:.*-rootless@sha256:' "$out/arc-runners.yaml" || { echo "render: arc-runners: buildkitd is not a rootless image pinned by digest"; fail=1; }
[ "$(yq -N 'select(.kind == "AutoscalingRunnerSet") | .spec.template.spec.automountServiceAccountToken' "$out/arc-runners.yaml" | sed '/^$/d')" = false ] \
  || { echo "render: arc-runners: runner pod mounts a service account token"; fail=1; }
[ "$(yq -N 'select(.kind == "Secret") | .kind' "$out/arc-controller.yaml" "$out/arc-runners.yaml" "$out/arc-config.yaml" | sed '/^$/d' | wc -l)" -eq 0 ] \
  || { echo "render: arc: Secret in the manifests"; fail=1; }
got=$(yq -N 'select(.kind == "CiliumNetworkPolicy" and .metadata.name == "runners") | .spec.egress[].toFQDNs[]? | .matchName // .matchPattern' "$out/arc-config.yaml" | sed '/^$/d' | sort | tr '\n' ' ')
want="*.actions.githubusercontent.com *.blob.core.windows.net api.github.com codeload.github.com get.helm.sh github.com objects.githubusercontent.com proxy.golang.org sum.golang.org "
[ "$got" = "$want" ] || { echo "render: arc-config: runners toFQDNs '$got'"; fail=1; }
[ "$(yq -N 'select(.kind == "ExternalSecret") | .spec.dataFrom[0].extract.key' "$out/arc-config.yaml" | sed '/^$/d')" = "ci/github" ] \
  || { echo "render: arc-config: ExternalSecret must read ci/github"; fail=1; }

# Karpenter and KWOK (SRS INF-1.2): the Karpenter chart is cloned from the tag of its Application, the KWOK charts come from their repository.
# One replica and the pinned image, requests and limits everywhere; the NodePool taint is tolerated by the demo workload only.
kver=$(yq eval '.spec.sources[0].targetRevision' apps/platform/karpenter.yaml)
kpath=$(yq eval '.spec.sources[0].path' apps/platform/karpenter.yaml)
if git clone -q --depth 1 --branch "$kver" https://github.com/kubernetes-sigs/karpenter "$out/karpenter-src" \
  && helm template karpenter "$out/karpenter-src/$kpath" --namespace karpenter -f platform/karpenter/values.yaml --include-crds >"$out/karpenter.yaml"; then
  check karpenter "$out/karpenter.yaml"
else
  echo "render: karpenter: clone or helm template failed"; fail=1
fi
kwokrepo=$(yq eval '.spec.sources[0].repoURL' apps/platform/kwok.yaml)
kwokver=$(yq eval '.spec.sources[0].targetRevision' apps/platform/kwok.yaml)
stagever=$(yq eval '.spec.source.targetRevision' apps/platform/kwok-stages.yaml)
if helm template kwok kwok --repo "$kwokrepo" --version "$kwokver" --namespace kube-system -f platform/kwok/values.yaml --include-crds >"$out/kwok.yaml" \
  && helm template kwok-stages stage-fast --repo "$kwokrepo" --version "$stagever" --namespace kube-system >"$out/kwok-stages.yaml"; then
  check kwok "$out/kwok.yaml"
  check kwok-stages "$out/kwok-stages.yaml"
else
  echo "render: kwok: helm template failed"; fail=1
fi
bad=$(yq -N 'select(.kind == "Deployment") | .spec.template.spec.containers[] | select(.resources.limits.memory == null or .resources.requests.memory == null) | .name' \
  "$out/karpenter.yaml" "$out/kwok.yaml" "$out/karpenter-config.yaml" | sed '/^$/d')
[ -z "$bad" ] || { echo "render: karpenter, kwok: no requests or limits: $bad"; fail=1; }
got=$(yq -N 'select(.kind == "Deployment") | [.spec.replicas, .spec.template.spec.containers[0].image] | join(" ")' "$out/karpenter.yaml" | sed '/^$/d')
[ "$got" = "2 ghcr.io/m5tshift/weigate/karpenter-kwok/kwok:v1.15.1" ] || { echo "render: karpenter: want 2 replicas and the GHCR image of $kver: $got"; fail=1; }
taint=$(yq -N 'select(.kind == "NodePool") | .spec.template.spec.taints[0] | .key + "=" + .value + ":" + .effect' "$out/karpenter-config.yaml" | sed '/^$/d')
[ "$taint" = "weigate.io/simulated=true:NoSchedule" ] || { echo "render: karpenter-config: NodePool taint '$taint'"; fail=1; }
tol=$(yq -N 'select(.kind == "Deployment") | .spec.template.spec.tolerations[0] | .key + "=" + .value + ":" + .effect' "$out/karpenter-config.yaml" | sed '/^$/d')
[ "$tol" = "$taint" ] || { echo "render: karpenter-config: demo toleration '$tol'"; fail=1; }
# No other workload of this repository may tolerate the taint.
other=$(grep -rl 'weigate.io/simulated' apps platform services 2>/dev/null | grep -v -e '^platform/karpenter/' -e '^platform/kwok/' || true)
[ -z "$other" ] || { echo "render: the taint weigate.io/simulated is used outside platform/karpenter: $other"; fail=1; }

exit "$fail"
