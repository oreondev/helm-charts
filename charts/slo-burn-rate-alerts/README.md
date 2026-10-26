# slo-burn-rate-alerts

Write your SLOs as Helm values and get, for each one:

- **Recording rules** for the error ratio over every alert window and over the SLO period, plus burn rate, objective, error budget and error budget remaining as metrics.
- **Multi-window, multi-burn-rate alerts** as in the Google SRE Workbook: a *page* alert (1h/5m at 14.4x or 6h/30m at 6x) and a *ticket* alert (1d/2h at 3x or 3d/6h at 1x).
- **A Grafana dashboard** (SLI, budget remaining, burn rates by window, all SLOs in one table, firing alerts), delivered as a ConfigMap for the Grafana sidecar.

No operator, no CRD of its own, no binary to run. It renders a `PrometheusRule` and a `ConfigMap`, which is what most teams end up hand-writing after reading the workbook chapter. Works with kube-prometheus-stack out of the box.

## Install

```bash
helm repo add oreonit https://oreondev.github.io/helm-charts
helm repo update
helm install slo oreonit/slo-burn-rate-alerts -n monitoring -f my-slos.yaml
```

`my-slos.yaml`:

```yaml
prometheusRule:
  labels:
    release: kube-prometheus-stack   # whatever your Prometheus ruleSelector expects

slos:
  - name: api-availability
    service: api
    objective: 99.9
    description: non-5xx responses over all responses
    sli:
      errorQuery: sum(rate(http_requests_total{job="api",code=~"5.."}[$WINDOW]))
      totalQuery: sum(rate(http_requests_total{job="api"}[$WINDOW]))

  - name: api-latency-300ms
    service: api
    objective: 95
    sli:
      errorQuery: sum(rate(http_request_duration_seconds_count{job="api"}[$WINDOW])) - sum(rate(http_request_duration_seconds_bucket{job="api",le="0.3"}[$WINDOW]))
      totalQuery: sum(rate(http_request_duration_seconds_count{job="api"}[$WINDOW]))
    alerting:
      page:
        enabled: false        # latency only opens tickets
```

Write `$WINDOW` wherever the range selector goes. The chart substitutes it for every window it needs (5m, 30m, 1h, 2h, 6h, 1d, 3d and the SLO period, 30d by default). `errorQuery / totalQuery` must be the share of **bad** events.

## What gets generated

For an SLO called `api-availability` with objective 99.9 (budget 0.001):

| Metric | Meaning |
|---|---|
| `slo:sli_error:ratio_rate<window>{slo="api-availability"}` | bad / total over `<window>` |
| `slo:error_budget_burn_rate:ratio_rate<window>` | error ratio divided by the budget (1 = burning exactly the budget) |
| `slo:objective:ratio` | 0.999 |
| `slo:error_budget:ratio` | 0.001 |
| `slo:period:days` | 30 |
| `slo:error_budget_remaining:ratio` | 1 - (error ratio over the period / budget); negative once the budget is spent |

Alerts (names configurable with `alerting.alertNamePrefix`):

| Alert | Fires when | Default severity | `for` |
|---|---|---|---|
| `SLOBurnRatePage` | burn rate > 14.4 on both 1h and 5m, **or** > 6 on both 6h and 30m | critical | 2m |
| `SLOBurnRateTicket` | burn rate > 3 on both 1d and 2h, **or** > 1 on both 3d and 6h | warning | 15m |

Both carry the labels `slo`, `service`, `slo_alert_type` (page/ticket), the SLO's own labels and `alerting.labels`, so routing in Alertmanager is one matcher.

Why these numbers: a burn rate of 14.4 on a 30-day SLO spends 2 % of the budget in an hour and the whole budget in about two days, which is worth a page. A burn rate of 1 spends exactly the budget and only deserves a ticket. The short window stops the alert from staying open long after the problem is fixed. If your period is not 30 days, set `sloPeriodDays` and recompute `factor = period_hours x budget_fraction / long_window_hours` in `alerting.*.windows`.

## Values

| Key | Default | Description |
|---|---|---|
| `sloPeriodDays` | `30` | SLO window in days |
| `rulesBackend` | `prometheus-operator` | `prometheus-operator` (PrometheusRule) or `gmp` (Google Managed Prometheus rules) |
| `gmp.kind` | `ClusterRules` | `Rules`, `ClusterRules` or `GlobalRules` when `rulesBackend: gmp` |
| `prometheusRule.enabled` | `true` | Render the rules object |
| `prometheusRule.namespace` | release namespace | Where to put it |
| `prometheusRule.labels` | `{}` | Labels for the Prometheus Operator ruleSelector |
| `prometheusRule.interval` | `30s` | Rule group evaluation interval |
| `dashboard.enabled` | `true` | Render the dashboard ConfigMap |
| `dashboard.labels` | `grafana_dashboard: "1"` | Label the Grafana sidecar watches |
| `dashboard.annotations` | `{}` | e.g. `grafana_folder: SLOs` |
| `alerting.alertNamePrefix` | `SLO` | Alert name prefix |
| `alerting.labels` / `annotations` | `{}` | Added to every alert |
| `alerting.page.*`, `alerting.ticket.*` | see values.yaml | enabled, severity, for, windows |
| `slos[]` | `[]` | name, service, objective, description, labels, sli.errorQuery, sli.totalQuery, alerting overrides |

Per-SLO `alerting.page` / `alerting.ticket` may override `enabled`, `severity` and `for`; `alerting.annotations` adds annotations (a `runbook_url` per SLO is the usual one).

## Google Managed Prometheus (GKE managed collection)

Managed collection does not read `PrometheusRule`. Set `rulesBackend: gmp` and the chart renders the same groups as a `ClusterRules` object (`monitoring.googleapis.com/v1`) that the managed rule evaluator loads by itself:

```yaml
rulesBackend: gmp
gmp:
  kind: ClusterRules      # or Rules (one namespace) / GlobalRules (whole project)
```

Alerts are sent to the Alertmanager named in the `OperatorConfig` (`gmp-public/config`); the dashboard works unchanged against the Managed Service for Prometheus data source in Grafana.

## Dashboard

Imported by the kube-prometheus-stack Grafana sidecar as **SLO overview and burn rates** (uid `oreon-slo-overview`). It has a data-source variable and an SLO variable fed from `slo:objective:ratio`, so it needs no editing. If you do not run the sidecar, `kubectl get cm <release>-slo-burn-rate-alerts-dashboard -o jsonpath='{.data.slo-overview\.json}'` gives you the JSON to import by hand.

## Notes and limits

- Only ratio SLIs (bad / total). Latency SLOs are ratio SLIs too: bad = requests slower than the threshold, as in the example above.
- One period for all SLOs in a release. Install the chart twice if you need 7-day and 30-day SLOs.
- The period-long recording rule (`rate(...[30d])`) is the expensive one. Keep the queries aggregated (`sum(...)`) and the label set small.
- Division by zero (no traffic) yields NaN, which never alerts. If "no traffic" is itself an incident, alert on `absent()` or on the total rate separately.
- Prometheus Operator must load the rule: with kube-prometheus-stack set `prometheusRule.labels` to its `release` label, or set `ruleSelectorNilUsesHelmValues=false` there.

Background reading: [how multi-window burn-rate alerts work](https://www.oreonit.com/advanced-alerting-strategies-how-to-avoid-alert-fatigue-in-monitoring-systems/) and [12 SLO and SLI examples with PromQL](https://www.oreonit.com/slo-sli-examples-targets-promql/). If you want the SLOs defined with you rather than by you, that is what our [SRE consulting](https://www.oreonit.com/site-reliability-engineering-sre-consulting-services/) does.

## Licence

MIT. Maintained by [Oreon IT](https://www.oreonit.com/).
