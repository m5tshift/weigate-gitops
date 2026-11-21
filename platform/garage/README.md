# Garage S3

Single-node Garage (SRS INF-1.3, 4.1.6) with buckets `pg-backups`, `mongo-backups`, `tempo-traces`. Endpoint inside the
cluster: `http://garage.data:3900`, region `garage`. Layout, buckets and keys are created by the `garage-bootstrap` Job.

Secrets are not in git. `ExternalSecret`s read them from OpenBao through the `openbao` ClusterSecretStore.
Before the first sync, the user puts the values into OpenBao (generated in the shell, not stored in files):

```sh
bao kv put -mount=secret garage/core \
  rpc-secret="$(openssl rand -hex 32)" \
  admin-token="$(openssl rand -base64 32)"

bao kv put -mount=secret garage/keys \
  pg-backups-access-key="GK$(openssl rand -hex 12)"    pg-backups-secret-key="$(openssl rand -hex 32)" \
  mongo-backups-access-key="GK$(openssl rand -hex 12)" mongo-backups-secret-key="$(openssl rand -hex 32)" \
  tempo-traces-access-key="GK$(openssl rand -hex 12)"  tempo-traces-secret-key="$(openssl rand -hex 32)"
```

`bao kv put` replaces the whole secret: to change one value, read the others first with `bao kv get`.
