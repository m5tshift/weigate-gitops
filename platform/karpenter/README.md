# Karpenter and KWOK

SRS INF-1.2, ADR 0006. Karpenter makes real decisions to add and remove nodes, the nodes are simulated by KWOK.

- `apps/platform/karpenter.yaml`: chart `kwok/charts` of kubernetes-sigs/karpenter v1.15.1 in the namespace `karpenter`,
  values in `values.yaml`. The image `ghcr.io/m5tshift/weigate/karpenter-kwok:v1.15.1` is built by `infra/karpenter-kwok`
  in weigate and must be public (no pull secret: OpenBao is not initialized on the minimal stand).
- `apps/platform/kwok.yaml`, `kwok-stages.yaml`: KWOK controller and its default Stages in `kube-system`
  (`platform/kwok/values.yaml`); it manages only nodes annotated `kwok.x-k8s.io/node=fake`.
- `apps/platform/karpenter-config.yaml`: `config/` holds the NodePool `kwok-demo` and the demo Deployment. Simulated nodes
  carry the taint `weigate.io/simulated=true:NoSchedule`; only the demo tolerates it, so the pods of the System stay on real nodes.

The chart always renders a PodDisruptionBudget (`maxUnavailable: 1`), it cannot be switched off: with one replica it blocks nothing.
Two replicas, moving the image to Zot: m5tshift/weigate#183.
