# blackbox-slo-probes

Synthetic monitoring that produces SLOs instead of a wall of up/down checks. A list of URLs becomes:

- a **Probe** object per target for the Prometheus Operator and the blackbox exporter (HTTP, TCP, DNS, ICMP modules);
- an **availability SLO** per target (share of successful probes over 30 days) and, where you set a threshold, a **latency SLO** (share of probes faster than N seconds), each with the same multi-window, multi-burn-rate page and ticket alerts as the [slo-burn-rate-alerts](../slo-burn-rate-alerts) chart;
- **ProbeDown** (the probe has failed for 3 minutes) and **ProbeTLSCertificateExpiringSoon** (under 14 days) alerts;
- a **dashboard** with uptime, budget remaining, latency by phase, probe timeline, TLS expiry and a table of every target.

The recording rules use the same metric names as slo-burn-rate-alerts (`slo:sli_error:ratio_rate<window>{slo="<target>-availability"}` and so on), so the targets also appear in that chart's SLO overview.

## Install

You need a blackbox exporter reachable from Prometheus; the simplest is the community chart:

```bash
helm install blackbox prometheus-community/prometheus-blackbox-exporter -n monitoring
```

Then:

```bash
helm repo add oreonit https://oreondev.github.io/helm-charts
helm install probes oreonit/blackbox-slo-probes -n monitoring -f probes.yaml
```

`probes.yaml`:

```yaml
blackbox:
  url: blackbox-prometheus-blackbox-exporter.monitoring.svc:9115

probe:
  labels:
    release: kube-prometheus-stack     # whatever your Prometheus probeSelector expects
prometheusRule:
  labels:
    release: kube-prometheus-stack

targets:
  - name: website
    url: https://www.example.com/
    availability:
      objective: 99.9
    latency:
      objective: 99
      threshold: 1.0
  - name: api-health
    url: https://api.example.com/healthz
    availability:
      objective: 99.95
  - name: postgres
    url: db.example.com:5432
    module: tcp_connect
```

## How the SLOs are computed

- Availability error ratio over a window = `1 - avg_over_time(probe_success[window])`. No division, no zero traffic problem; the series is simply absent until the first probe.
- Latency: a recording rule marks each probe slower than the threshold (`probe_duration_seconds > bool threshold`), and the error ratio is the average of that flag over the window.
- Burn rate = error ratio / error budget. Page at 14.4x (1h/5m) or 6x (6h/30m); ticket at 3x (1d/2h) or 1x (3d/6h). See the slo-burn-rate-alerts README for the arithmetic.

With a 30-second interval a 99.9 % objective allows about 86 failed probes a month. Pick the objective to match what the page or API promises, not what the probe happens to achieve.

## Values

| Key | Default | Description |
|---|---|---|
| `blackbox.url` / `scheme` / `path` | `prometheus-blackbox-exporter.monitoring.svc:9115` / `http` / `/probe` | Where the exporter is |
| `probe.jobName` | `blackbox-slo` | `job` label on the metrics |
| `probe.interval` / `scrapeTimeout` | `30s` / `10s` | Probe frequency |
| `probe.module` | `http_2xx` | Default exporter module |
| `probe.labels` | `{}` | Prometheus Operator probeSelector labels |
| `sloPeriodDays` | `30` | SLO window |
| `prometheusRule.*` | enabled, `interval: 30s` | Rules object |
| `dashboard.*` | enabled | Dashboard ConfigMap |
| `alerting.page` / `ticket` | workbook windows | Burn-rate alert classes |
| `alerting.probeDown` | critical, 3m | Continuous failure alert |
| `alerting.tlsExpiry` | warning, 14 days | Certificate alert |
| `targets[]` | `[]` | `name`, `url`, `service`, `module`, `labels`, `availability.objective`, `latency.{objective,threshold}` |

## Notes

- Modules other than `http_2xx` and `tcp_connect` need to exist in the exporter's configuration (`icmp`, `dns`, `http_post_2xx` and so on).
- Probe from more than one place if you can: a second exporter in another region, with a second release of this chart, tells you whether it is the site or the network.
- A probe measures the path from the exporter to the target, not what your users see; keep real-user or request-based SLOs for the services behind the URL.

Related reading: [SLO and SLI examples](https://www.oreonit.com/slo-sli-examples-targets-promql/). If you would like the targets, objectives and on-call routing set up together, see our [observability consulting](https://www.oreonit.com/observability-and-monitoring-consultancy-services/).

## Licence

MIT. Maintained by [Oreon IT](https://www.oreonit.com/).
