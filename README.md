# Oreon IT Helm charts

Charts we install on client clusters, published so you can use them too.

| Chart | What it does |
|---|---|
| [slo-burn-rate-alerts](charts/slo-burn-rate-alerts) | Define SLOs in values; get Prometheus recording rules, multi-window multi-burn-rate page/ticket alerts and a Grafana SLO dashboard. For Prometheus Operator / kube-prometheus-stack. |
| [namespace-baseline](charts/namespace-baseline) | Guardrails for team namespaces: Pod Security Admission labels, ResourceQuota, LimitRange, default-deny NetworkPolicies with the usual allows, RBAC bindings, optional quota alerts. |

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

Pull requests run [chart-testing](https://github.com/helm/chart-testing) (lint, then install on a kind cluster). Pushes to `main` that change a chart version are packaged and published to the `gh-pages` branch by [chart-releaser](https://github.com/helm/chart-releaser), which also updates `index.yaml`.

### First-time publishing checklist

1. Create an empty `gh-pages` branch once: `git checkout --orphan gh-pages && git rm -rf . && git commit --allow-empty -m "gh-pages" && git push origin gh-pages && git checkout main`.
2. Repository settings, Pages: source = branch `gh-pages`, folder `/`.
3. Push `main`; the release workflow creates a GitHub release per chart and the Helm index at `https://oreonit.github.io/helm-charts/index.yaml`.
4. On Artifact Hub, add a Helm repository with that URL. Paste the repository ID it shows into `artifacthub-repo.yml` (the workflow copies the file to `gh-pages`) to get the verified-publisher badge.

## Contributing

Issues and pull requests are welcome. Keep charts CRD-free where possible, keep `values.schema.json` in step with `values.yaml`, bump `version` in `Chart.yaml` for every change (the release workflow keys on it).

## Licence

MIT. Maintained by [Oreon IT](https://www.oreonit.com/), a DevOps, SRE and cloud consultancy in London. If you want [SLOs defined](https://www.oreonit.com/site-reliability-engineering-sre-consulting-services/) or a [multi-team Kubernetes platform](https://www.oreonit.com/containerization-orchestration-management-kubernetes-openshift/) built with you, that is the day job.
