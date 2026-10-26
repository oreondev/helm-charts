# k8s-cost-waste-alerts

Where the money goes in a Kubernetes cluster, as Prometheus rules and a Grafana dashboard. No agents, no SaaS, no cloud billing export: only kube-state-metrics and the kubelet's cAdvisor metrics, which kube-prometheus-stack already scrapes.

| Alert | Fires when | Default |
|---|---|---|
| `NamespaceCPUOverRequested` | a namespace leaves more than 70 % of its CPU requests unused (24 h average) and requests at least 2 cores | warning, 1h |
| `NamespaceMemoryOverRequested` | same for memory, at least 4 GiB requested | warning, 1h |
| `ClusterCPUUnderCommitted` / `ClusterMemoryUnderCommitted` | less than 40 % of allocatable capacity is requested across the cluster (nodes oversized or autoscaler not scaling in) | info, 6h |
| `UnusedPersistentVolumeClaim` | a PVC has not been mounted by any pod for 7 days | info, 7d |
| `UnusedLoadBalancerService` | a LoadBalancer service has had no ready endpoints for a day | warning, 1d |
| `HPAAtMaxReplicas` | an HPA has sat at maxReplicas for 2 hours | info, 2h |
| `HPAMinEqualsMax` | an HPA has minReplicas equal to maxReplicas (autoscaling off) | info, 1h |
| `ContainersWithoutCPURequests` | running containers in a namespace have no CPU request | info, 1h |
| `DeploymentScaledToZero` | a Deployment has had zero replicas for 7 days | info, 7d |

Recording rules (`costwaste:*`) give requested, used and wasted CPU and memory per namespace, cluster commitment ratios, and the waste priced per month with your rates. The dashboard turns that into a sortable namespace table, a top-10 bar chart, cluster trend lines, and lists of idle volumes and HPAs.

## Install

```bash
helm repo add oreonit https://oreonit.github.io/helm-charts
helm install cost oreonit/k8s-cost-waste-alerts -n monitoring \
  --set prometheusRule.labels.release=kube-prometheus-stack \
  --set pricing.currency=GBP --set pricing.cpuCoreHour=0.026 --set pricing.memoryGiBHour=0.0035
```

The over-requested alerts use a 24-hour average, so they start firing a day after install. The dashboard is useful after a few minutes.

## Values

| Key | Default | Description |
|---|---|---|
| `prometheusRule.labels` | `{}` | Prometheus Operator ruleSelector labels |
| `prometheusRule.interval` | `1m` | Recording rule interval |
| `dashboard.*` | enabled, `grafana_dashboard: "1"` | Dashboard ConfigMap for the Grafana sidecar |
| `excludeNamespaces` | `kube-.*\|gmp-.*\|gke-.*\|monitoring\|kyverno` | Regex of namespaces the alerts ignore |
| `pricing.currency` | `USD` | `USD`, `GBP` or `EUR` (dashboard unit) |
| `pricing.cpuCoreHour` | `0.032` | Price of one vCPU-hour |
| `pricing.memoryGiBHour` | `0.0043` | Price of one GiB-hour |
| `thresholds.cpuWasteRatio` / `memoryWasteRatio` | `0.7` | Unused share of requests that triggers the over-requested alerts |
| `thresholds.minCpuRequestCores` / `minMemoryRequestGiB` | `2` / `4` | Ignore namespaces requesting less than this |
| `thresholds.clusterCpuCommitRatio` / `clusterMemoryCommitRatio` | `0.4` | Under-committed threshold |
| `alerts.<name>.enabled` / `severity` / `for` | see table | Per-alert switches |
| `alertLabels` | `{}` | Labels added to every alert (team, routing) |

## How to read it

- **Over-requested namespaces** are the usual first win: memory requests set "to be safe" decide how many nodes you pay for. Right-size with VPA recommendations, then let the autoscaler remove nodes.
- **Under-committed cluster** with over-requested namespaces means both problems at once: fix requests first, then node pool minimums and machine types.
- **Prices** are a model, not an invoice. Use your blended rate (reserved, committed-use, spot mix) and the numbers become decision-grade.
- `UnusedLoadBalancerService` needs kube-state-metrics 2.6 or newer (`kube_endpoint_address`); on older versions it stays silent rather than guessing.

Background: [GKE cost optimisation levers](https://www.oreonit.com/gke-cost-optimization-levers-that-work/), [EKS cost optimisation](https://www.oreonit.com/eks-cost-optimization-12-levers-that-actually-work/), [cost observability and FinOps](https://www.oreonit.com/cost-observability-finops/). If you want the findings turned into a prioritised savings plan with the changes made, that is the [cloud cost optimisation review](https://www.oreonit.com/cloud-cost-optimization-review/).

## Licence

MIT. Maintained by [Oreon IT](https://www.oreonit.com/).
