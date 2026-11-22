# Observability

Stack of SRS 4.5: VictoriaMetrics, VictoriaLogs, Tempo (blocks in the Garage bucket `tempo-traces`), Grafana,
vmalert and Alertmanager in `observability`; OTel Collector (DaemonSet) and Target Allocator in `kube-system`.

- Services send traces and logs over OTLP/HTTP to `otel-collector.kube-system:4318`; metrics are scraped from `/metrics`, OTLP metrics are not accepted. Pod logs are tailed by the collector of each node.
- Alert rules (SRS 4.5.4) are inline in `vmalert/values.yaml`; `make alerts` checks them with `vmalert -dryRun`.
  Volume usage (`kubelet_volume_stats_*`) comes from a static kubelet scrape of the OTel Collector.
- Metrics are scraped by the collectors from every ServiceMonitor and PodMonitor (`config/monitors.yaml`, charts).
  Pods with a sidecar are read on the merged istio agent endpoint `:15020/stats/prometheus`.
- Grafana: `kubectl -n observability port-forward svc/grafana 3000:80`. Dashboards of SRS 4.5.3 (folder Weigate) are JSON
  files in `config/dashboards/`, provisioned from ConfigMap `grafana-dashboards`; `make dashboards` checks JSON and metric
  names. Kafka panels stay empty until the Kafka CR has JMX Exporter and Kafka Exporter; Hubble — full stand only.

| Component | requests | limits |
|---|---|---|
| VictoriaMetrics | 192Mi | 448Mi |
| VictoriaLogs | 96Mi | 256Mi |
| Tempo | 192Mi | 448Mi |
| Grafana | 96Mi | 256Mi |
| OTel Collector (3 nodes × 96Mi/192Mi) | 288Mi | 576Mi |
| OTel Target Allocator | 48Mi | 96Mi |
| vmalert | 48Mi | 96Mi |
| Alertmanager | 32Mi | 64Mi |
| kube-state-metrics | 48Mi | 128Mi |
| **Total** | **1040Mi** | **2368Mi** (SRS 6.2: ~2.5 GB) |

Secrets are not in git. Before the first sync, the user puts the values into OpenBao (Garage keys of `tempo-traces`
are already in `garage/keys`):

```sh
bao kv put -mount=secret grafana/admin admin-user=admin admin-password="$(openssl rand -base64 24)"
bao kv put -mount=secret alertmanager/telegram telegram-bot-token=<bot token> telegram-chat-id=<chat id>
```
