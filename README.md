# Oreon IT Helm charts

Charts we install on client clusters, published so you can use them too. None of them installs Prometheus, Grafana, Kyverno or Velero: each one packages the configuration that teams otherwise hand-write on top of those tools.

| Chart | What it does | Needs |
|---|---|---|
| [slo-burn-rate-alerts](charts/slo-burn-rate-alerts) | SLOs as values: recording rules, multi-window multi-burn-rate page/ticket alerts and an SLO dashboard. Prometheus Operator or Google Managed Prometheus backends. | Prometheus Operator / GMP, Grafana sidecar |
| [blackbox-slo-probes](charts/blackbox-slo-probes) | URLs become Probe objects plus availability and latency SLOs with the same burn-rate alerts, probe-down and TLS-expiry alerts, and a dashboard. | blackbox exporter, Prometheus Operator |
| [alertmanager-routing-baseline](charts/alertmanager-routing-baseline) | Teams, page/ticket receivers (Slack, PagerDuty, Opsgenie, email, Teams, webhook), severity routing, inhibition, business-hours muting, Watchdog sink, as an AlertmanagerConfig. | Prometheus Operator |
| [k8s-cost-waste-alerts](charts/k8s-cost-waste-alerts) | Requests vs usage per namespace priced per month, under-committed clusters, idle PVCs, LoadBalancers without endpoints, HPAs at max or pinned, containers without requests. Rules and a dashboard. | kube-state-metrics, cAdvisor |
| [kyverno-production-policies](charts/kyverno-production-policies) | The production readiness checklist as Kyverno policies: requests/limits, probes, labels, no latest tags, PDBs and spread for multi-replica workloads, no NodePorts, nothing in default. Audit mode first. | Kyverno 1.13+ |
| [namespace-baseline](charts/namespace-baseline) | Guardrails per team namespace: Pod Security Admission labels, ResourceQuota, LimitRange, default-deny NetworkPolicies with the usual allows, RBAC bindings, optional quota alerts. | a CNI that enforces NetworkPolicy |
| [velero-backup-schedules](charts/velero-backup-schedules) | Daily/weekly/monthly Velero Schedules with retention, optional storage locations, a scheduled restore test into a scratch namespace, and backup alerts. | Velero |

## Use

```bash
helm repo add oreonit https://oreonit.github.io/helm-charts
helm repo update
helm search repo oreonit
```

The charts are also listed on [Artifact Hub](https://artifacthub.io/packages/search?repo=oreonit).

## Develop

```bash
helm lint charts/slo-burn-rate-alerts -f charts/slo-burn-rate-alerts/ci/test-values.yaml
helm template slo charts/slo-burn-rate-alerts -f charts/slo-burn-rate-alerts/ci/test-values.yaml
```

Pull requests run [chart-testing](https://github.com/helm/chart-testing) (lint, then install on a kind cluster with the Prometheus Operator CRDs). Pushes to `main` that change a chart version are packaged and published to the `gh-pages` branch by [chart-releaser](https://github.com/helm/chart-releaser), which also updates `index.yaml`.

### First-time publishing checklist

1. Create an empty `gh-pages` branch once: `git checkout --orphan gh-pages && git rm -rf . && git commit --allow-empty -m "gh-pages" && git push origin gh-pages && git checkout main`.
2. Repository settings, Pages: source = branch `gh-pages`, folder `/`.
3. Push `main`; the release workflow creates a GitHub release per chart and the Helm index at `https://oreonit.github.io/helm-charts/index.yaml`.
4. On Artifact Hub, add a Helm repository with that URL. Paste the repository ID it shows into `artifacthub-repo.yml` (the workflow copies the file to `gh-pages`) to get the verified-publisher badge.

## Contributing

Issues and pull requests are welcome. Keep charts CRD-free where possible, keep `values.schema.json` in step with `values.yaml`, bump `version` in `Chart.yaml` for every change (the release workflow keys on it).

## Licence

MIT. Maintained by [Oreon IT](https://www.oreonit.com/), a DevOps, SRE and cloud consultancy in London. If you want [SLOs defined](https://www.oreonit.com/site-reliability-engineering-sre-consulting-services/), a [multi-team Kubernetes platform](https://www.oreonit.com/containerization-orchestration-management-kubernetes-openshift/) or a [tested disaster recovery plan](https://www.oreonit.com/disaster-recovery-planning-services/) built with you, that is the day job.
