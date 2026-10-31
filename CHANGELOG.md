# Changelog

Every chart is versioned on its own ([SemVer](https://semver.org/): patch for fixes, minor for new features or changed defaults, major for changes that need action on upgrade). A release is any push to `main` that changes a chart's `version`; chart-releaser then publishes it to the Helm repository and Artifact Hub. Each release also carries the same notes in its `artifacthub.io/changes` annotation.

| Chart | Version | App version | Status |
|---|---|---|---|
| alertmanager-routing-baseline | 0.1.0 | - | released |
| blackbox-slo-probes | 0.1.1 | - | released |
| crawl4ai | 0.1.0 | Crawl4AI 0.9.5 | released |
| gateway-api-baseline | 0.1.0 | - | released |
| k8s-cost-waste-alerts | 0.2.1 | - | released |
| kyverno-production-policies | 0.1.1 | - | released |
| namespace-baseline | 0.1.0 | - | released |
| otel-collector-baseline | 0.1.3 | - | released |
| slo-burn-rate-alerts | 0.3.2 | - | released |
| velero-backup-schedules | 0.1.0 | - | released |

## 2026-10-31

### crawl4ai 0.1.0 (Crawl4AI 0.9.5)

First release.
- gunicorn as PID 1 from a rendered `gunicorn.conf.py` instead of supervisord. A `post_worker_init` hook bounds the egress proxy's shutdown wait: upstream hangs about 30 s after the first crawl and is killed.
- Redis as a native sidecar (default, same image), or external Redis for more than one replica. Jobs submitted on one pod can be polled on another.
- Generated API token and JWT signing key, kept across upgrades. The cloud advert banner is off.
- `crawler.memory_threshold_percent` 85 (upstream 95). The upstream `config.yml` ships with the chart and `config` is deep-merged over it.
- Security flags as values: deep crawl, hooks, `/execute_js`, internal URLs, Chromium sandbox. All are off by default.
- Non-root (uid 999), read-only root filesystem, sized emptyDirs. The artifact quota follows `artifacts.size`.
- HPA, PodDisruptionBudget and topology spread when more than one replica can run.
- Ingress, Gateway API HTTPRoute, `gunicorn.forwardedAllowIps` for per-client rate limits.
- ServiceMonitor with bearer auth, five alerts, Grafana dashboard.
- Measured against the image entrypoint, with the same limits:

  | | Image entrypoint | Chart |
  |---|---|---|
  | Ready | 6.0-6.9 s | 4.0 s |
  | Idle memory | 399-483 MiB | 261 MiB |
  | Stop after a crawl | 12 s | 2.7 s |

### Repository

- The ServiceMonitor and PodMonitor CRDs are installed in CI.

## 2026-10-27

- **slo-burn-rate-alerts 0.3.2:** the burn-rate panel floors values at 0.001, so zero burn still draws on the log axis.
- **slo-burn-rate-alerts 0.3.1:** dashboard fixes found while taking the grafana.com screenshots:
  - All SLOs groups by slo and service.
  - "Not burning" shows as a value.
  - Alert history shows "No alerts" when there are none.
  - Burn-rate axis labels have two decimals.
  - `dashboards/` is regenerated on every release.
- **slo-burn-rate-alerts 0.3.0:**
  - OpenSLO v1 input (`openslo`): kind SLO with an inline indicator or `indicatorRef`.
  - Occurrences ratio SLOs with good/total or bad/total; `$WINDOW` or `{{.window}}` as the range.
  - Unsupported input fails with the reason. Existing values render unchanged.
- **k8s-cost-waste-alerts 0.2.1:** the Nodes and Namespaces tables group by node and namespace (rows were split).
- **k8s-cost-waste-alerts 0.2.0:**
  - `pricing.source`: static, instanceType (price list, spot discount) or opencost.
  - Cluster cost, cost per namespace, unrequested capacity and priced waste.
  - Savings levers: right-sizing, consolidation, spot, commitments, idle volumes and load balancers.
  - Fix: kube-state-metrics series re-exported by OpenCost were counted twice.
  - New dashboard cost tiles.
- **blackbox-slo-probes 0.1.1:** the All targets table groups by slo_target and service; the burn-rate panel uses a linear scale.
- **otel-collector-baseline 0.1.3:** failure panels read "None in this range"; traces held in memory are on their own axis.

## 2026-10-26

- **slo-burn-rate-alerts 0.2.1:**
  - `errorQuery` falls back to `0 * totalQuery`, so error-free windows record 0 instead of nothing.
  - Six new SLO dashboard panels.
- **otel-collector-baseline 0.1.2:** ten new dashboard panels, including processor in/out, batch sizes, exporter in-flight, memory against the limit and tail sampling.
- **otel-collector-baseline 0.1.1:**
  - Alerts no longer select several counters with one `__name__` regex.
  - The processor alert watches `memory_limiter_refused_*`.
  - k8sattributes extracts `container.image.tags`.
- **kyverno-production-policies 0.1.1:** require-pdb compares against `spec.selector.matchLabels`; every multi-replica workload was denied before.
- **Sources and Helm repository URL** moved to the oreondev GitHub organisation; chart icons now come from oreondev.
- **First releases:**
  - gateway-api-baseline 0.1.0
  - otel-collector-baseline 0.1.0
  - kyverno-production-policies 0.1.0
  - alertmanager-routing-baseline 0.1.0
  - k8s-cost-waste-alerts 0.1.0
  - blackbox-slo-probes 0.1.0
  - velero-backup-schedules 0.1.0
  - slo-burn-rate-alerts 0.2.0 (Google Managed Prometheus backend)
  - slo-burn-rate-alerts 0.1.0
  - namespace-baseline 0.1.0
