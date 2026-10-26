# alertmanager-routing-baseline

Alertmanager routing that most teams end up hand-writing, generated from a values file:

- **Teams**: a set of matchers per team (label `team`, a namespace regex, whatever you use), each with a *page* receiver, a *ticket* receiver and an optional *info* receiver.
- **Severity routing**: `critical` pages with its own repeat interval, `warning` goes to chat or a ticket, `info` goes to the info receiver and repeats once a day.
- **Receivers**: Slack, PagerDuty, Opsgenie, email, Microsoft Teams, webhook, with secrets referenced from Kubernetes Secrets and sensible Slack message templates.
- **Inhibition**: a critical alert silences warnings with the same alertname and namespace; an SLO page silences the ticket of the same SLO (labels from the [slo-burn-rate-alerts](../slo-burn-rate-alerts) chart).
- **Business hours**: per team, mute tickets and info outside working hours while pages still page.
- **Watchdog**: the permanent kube-prometheus-stack liveness alert goes to a dead-man's-switch receiver or is dropped, never to a human.
- **Fallback**: unmatched alerts have a home; unmatched pages have a pager.

It renders one `AlertmanagerConfig` (`monitoring.coreos.com/v1alpha1`) for the Prometheus Operator.

## Install

```bash
kubectl -n monitoring create secret generic alertmanager-secrets \
  --from-literal=platform-slack-webhook=https://hooks.slack.com/services/... \
  --from-literal=platform-pagerduty-routing-key=...

helm repo add oreonit https://oreonit.github.io/helm-charts
helm install routing oreonit/alertmanager-routing-baseline -n monitoring -f routing.yaml
```

`routing.yaml`:

```yaml
receivers:
  platform-slack:
    slack:
      apiURL: {name: alertmanager-secrets, key: platform-slack-webhook}
      channel: "#platform-alerts"
  platform-pager:
    pagerduty:
      routingKey: {name: alertmanager-secrets, key: platform-pagerduty-routing-key}
      severity: critical

teams:
  - name: platform
    matchers: ["team=platform"]
    page: platform-pager
    ticket: platform-slack
  - name: payments
    matchers:
      - {name: namespace, value: "payments|checkout", matchType: "=~"}
    page: platform-pager
    ticket: platform-slack
    muteTicketsOutsideBusinessHours: true

fallback:
  receiver: platform-slack
  page: platform-pager
```

## Global or namespaced: read this

The Prometheus Operator, by default, adds a `namespace="<object's namespace>"` matcher to every route of an `AlertmanagerConfig`, so the object only routes alerts from its own namespace. For a cluster-wide routing tree do one of these in kube-prometheus-stack:

```yaml
alertmanager:
  alertmanagerSpec:
    # Option A: let AlertmanagerConfigs match alerts from any namespace
    alertmanagerConfigMatcherStrategy:
      type: None
    # Option B: make this object the whole configuration (must be in Alertmanager's namespace)
    alertmanagerConfiguration:
      name: routing-baseline
```

With option B the operator uses this object as the root config; `alertmanagerConfigSelector` is no longer needed. Without either option the chart still works, but only for alerts carrying the release namespace.

Alerts from the Prometheus Operator's own rules (kube-prometheus-stack defaults) have no `team` label. Give them one in your `additionalRuleLabels`, or route them by `namespace` as in the payments example, or let them land in `fallback.receiver`.

## Values

| Key | Default | Description |
|---|---|---|
| `name` | `routing-baseline` | AlertmanagerConfig name |
| `labels` | `{}` | Labels for the Alertmanager's `alertmanagerConfigSelector` |
| `route.groupBy` | `[alertname, namespace]` | Grouping labels |
| `route.groupWait` / `groupInterval` / `repeatInterval` | `30s` / `5m` / `4h` | Root route timings |
| `route.pageRepeatInterval` | `1h` | Repeat interval for page severities |
| `severity.label` | `severity` | Label carrying severity |
| `severity.page` / `ticket` / `info` | `[critical]` / `[warning]` / `[info]` | Severity values per class |
| `receivers.<name>.<integration>` | `{}` | `slack`, `pagerduty`, `opsgenie`, `email`, `msteams`, `webhook`; the map is the AlertmanagerConfig field set for that integration |
| `slackDefaults.title` / `text` | see values.yaml | Slack templates applied when a receiver sets none |
| `teams[]` | `[]` | `name`, `matchers`, `page`, `ticket`, `info`, `muteTicketsOutsideBusinessHours` |
| `fallback.receiver` / `fallback.page` | `""` | Receivers for unmatched alerts / unmatched pages |
| `watchdog.*` | enabled, `Watchdog`, null receiver | Where the liveness alert goes |
| `inhibit.criticalInhibitsWarning` | `true` | Same alertname+namespace |
| `inhibit.pageInhibitsTicket` | `true` | Same `slo` label |
| `inhibit.extra` | `[]` | Raw inhibitRules |
| `timeIntervals.businessHours` | Mon–Fri 09:00–18:00 UTC | Defines "outside business hours" |
| `timeIntervals.extra` | `[]` | Raw muteTimeIntervals (maintenance, holidays) |
| `extraRoutes` | `[]` | Raw routes tried before the team routes |
| `nullReceiver` | `null` | Name of the drop receiver |

Matchers accept strings (`team=platform`, `namespace=~"a|b"`, `severity!=info`) or objects (`{name, value, matchType}`).

## Notes

- Secrets must live in the release namespace; the operator copies them into the generated Alertmanager configuration.
- Microsoft Teams receivers need Prometheus Operator 0.69 or newer.
- Time intervals are evaluated in UTC by Alertmanager unless the Alertmanager itself is configured with a location; adjust `start`/`end` accordingly.
- The chart fails rendering if a team or fallback names a receiver that is not defined, which is cheaper than finding out at 3 a.m.

The routing here follows the on-call model we run for clients under [SRE as a service](https://www.oreonit.com/sre-as-a-service/): pages are rare and actionable, everything else is a ticket, and nothing wakes anyone for information.

## Licence

MIT. Maintained by [Oreon IT](https://www.oreonit.com/).
