# Zot

Single-node Zot (SRS INF-1.4, CI-5.3): pull-through cache of `docker.io`, `ghcr.io`, `quay.io`, `registry.k8s.io`
and storage for OCI charts. NodePort 30500, inside the cluster `http://zot.registry:5000`.

Each upstream is served under its own path: `http://<node>:30500/v2/<host>/<repo>`. Talos asks for it that way
(`registries.mirrors` with `overridePath` in the `full-stand` patch of `weigate`). Reading is anonymous; pushing
from CI needs credentials and is added with the CI runners.
