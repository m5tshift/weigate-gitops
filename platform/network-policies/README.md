# Network policies

Cilium policies of SRS 4.1.10 and 4.1.11: default-deny in the namespaces of applications and data, explicit allows
by the graph of SRS 4.1. One file per namespace in `policies/`, the Application is `apps/network-policies.yaml`
(wave 5, after every workload).

Not synced on the minimal stand (SRS 6.4): it runs flannel and kube-proxy, the `CiliumNetworkPolicy` CRD does not exist.
The Application moves to `apps/platform` with m5tshift/weigate#183, after the cluster is rebuilt with Cilium.

## How the rules are built

- A policy that selects a pod puts it into default-deny for the directions it has rules for. Every namespace below has a
  `default` policy with `endpointSelector: {}` and both directions (only ingress in `ci`: the egress of the runners and the
  controller is in `platform/arc/config/policies.yaml`).
- `default` allows DNS to `kube-system/kube-dns` (through the DNS proxy of Cilium, needed by `toFQDNs`) and scraping by the
  OTel Collector (`kube-system`). In `data`, `kafka` and `secrets` it also opens the namespace to itself (operators and
  instances, backups, jobs) and the Kubernetes API in both directions (operators, admission webhooks).
- In `apps` the graph is checked on ingress of the receiver: egress of a service is open inside `apps` and to the
  namespaces `data`, `kafka`, `chain`, `secrets`; ingress of each receiver lists its callers.
- Only L3/L4 rules: the pods of `apps` carry an Istio sidecar with mTLS STRICT, Cilium sees the ports of the applications.

## Matrix

| From | To | Port |
|---|---|---|
| `istio-system/istio=gateway` | `merchant-service`, `invoice-service`, `ledger-service`, `reporting-service` | 8080 |
| `invoice-service` | `rate-service`, `merchant-service` (JWKS) | 8080 |
| `reconciliation-service` | `ledger-service` | 8080 |
| `payer-sim` | `invoice-service` | 8080 |
| `rate-service` | `rate-mock` | 8080 |
| `webhook-service` | `merchant-mock` | 8080 |
| `rate-service` | `api.exchange.coinbase.com`, `www.okx.com` (`toFQDNs`) | 443 |
| every pod of `apps` | `istio-system/istiod` | 15012 |
| every pod of `apps` | `kube-system/otel-collector` | 4318 |
| `chain-watcher`, `rate-service`, `reconciliation-service` (Lease), `merchant-service`, `webhook-service` (OpenBao login) | Kubernetes API | any |
| `merchant-service`, `invoice-service`, `chain-watcher`, `rate-service`, `webhook-service`, `ledger-service`, `reconciliation-service` | `kafka`: brokers of `weigate` | 9092 |
| `data`: ClickHouse | `kafka`: brokers of `weigate` | 9092 |
| `invoice-service` | `data/invoice-pg` | 5432 |
| `merchant-service` | `data/merchant-pg` | 5432 |
| `ledger-service` | `data/ledger-pg` | 5432 |
| `secrets/openbao` (database engine) | `data`: every CloudNativePG cluster | 5432 |
| `chain-watcher`, `webhook-service`, `reconciliation-service` | `data/mongodb` | 27017 |
| `invoice-service`, `chain-watcher`, `rate-service`, `webhook-service`, `istio-system/envoy-rls` | `data/valkey` | 6379 |
| `reporting-service` | `data`: ClickHouse `weigate` | 8123, 9000 |
| `observability/tempo` | `data/garage` | 3900 |
| `chain-watcher`, `reconciliation-service`, `payer-sim` | `chain/anvil` | 8545 |
| `merchant-service`, `webhook-service` | `secrets/openbao` | 8200 |
| `kube-system/otel-collector` | every pod of `apps`, `data`, `kafka`, `chain`, `secrets`, `ci` | any |
| a pod of `data`, `kafka`, `secrets` | the same namespace | any |
| a pod of `data`, `kafka`, `secrets` | Kubernetes API; Kubernetes API → the pod | any |
| every pod of the namespaces below | `kube-system/kube-dns` | 53 |

Everything else into and out of `apps`, `data`, `kafka`, `chain`, `secrets` and into `ci` is denied. Rules of services that
are not deployed yet (`ledger-service`, `reconciliation-service`, `webhook-service`, `reporting-service`, ClickHouse,
`ledger-pg`) select nothing until they are.

## Namespaces without default-deny

| Namespace | Why |
|---|---|
| `argocd` | a wrong policy must stay revertable through git |
| `kube-system`, `istio-system`, `cert-manager`, `observability`, `local-path-storage`, `karpenter` | cluster and platform services, not applications or data |
| `registry` | containerd of the nodes pulls through Zot from the host network |

## Assumptions

- Kubelet probes and `kubectl port-forward` come from the node itself and pass with the Cilium default `allow-localhost`.
- With `kubeProxyReplacement` the policy sees the backend address of the API server (6443 on the control plane), so
  `kube-apiserver` rules have no ports.
