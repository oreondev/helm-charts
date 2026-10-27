# k8s-cost-waste-alerts

What a Kubernetes cluster costs, who uses it, and where the money is wasted, as Prometheus rules and a Grafana dashboard. No SaaS and no cloud billing export: kube-state-metrics and the kubelet's cAdvisor metrics, which kube-prometheus-stack already scrapes, plus node prices from a flat rate, your instance-type price list, or [OpenCost](https://www.opencost.io/).

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

Recording rules (`costwaste:*`) price every node, then give:

- **Cluster cost per month** and the split into **requested** (what pods reserve) and **unrequested** capacity (paid for, used by nobody).
- **Showback per namespace**: requests priced at the node each pod runs on.
- **Waste per namespace**: requests above real usage, in money. The headline figure leaves out the system namespaces in `excludeNamespaces`; an "all namespaces" figure sits next to it.
- **Savings levers** per month: right-sizing, consolidating unrequested capacity, moving on-demand nodes to spot, committing the steady baseline, idle volumes and idle load balancers. They overlap, so read them as separate options, not a total.
- Cluster commitment ratios, idle PVCs and LoadBalancers, HPAs at their limits, containers without requests.

The dashboard shows all of it: cost tiles, a savings table, cost by namespace, a node table (instance type, spot or on-demand, cost, how much is requested), monthly run-rate trends, and the namespace table.

## Pricing sources

| `pricing.source` | Node price comes from | Needs |
|---|---|---|
| `static` (default) | `cpuCoreHour` × vCPUs + `memoryGiBHour` × GiB, the same for every node | nothing |
| `instanceType` | `pricing.instanceTypes` (on-demand $/hour per `node.kubernetes.io/instance-type`), spot nodes discounted by `spotDiscount`; unknown types fall back to the static rates | node labels in kube-state-metrics (below) |
| `opencost` | OpenCost's `node_total_hourly_cost`, `node_cpu_hourly_cost`, `node_ram_hourly_cost`, `kubecost_node_is_spot`: the cloud provider's price list, spot included | OpenCost scraped by the same Prometheus |

With `instanceType`, kube-state-metrics has to export the node labels. In kube-prometheus-stack:

```yaml
kube-state-metrics:
  metricLabelsAllowlist:
    - nodes=[node.kubernetes.io/instance-type,karpenter.sh/capacity-type,eks.amazonaws.com/capacityType,cloud.google.com/gke-spot,cloud.google.com/gke-preemptible,kubernetes.azure.com/scalesetpriority]
```

Spot and preemptible nodes are recognised from the Karpenter, EKS, GKE and AKS labels above (all sources) or from OpenCost.

```yaml
pricing:
  source: instanceType
  currency: USD
  instanceTypes:
    m6i.large: 0.096
    m6i.xlarge: 0.192
    m6i.2xlarge: 0.384
```

An instance price is split into CPU and memory in the ratio of `cpuCoreHour` to `memoryGiBHour`, so keep those two at sensible list prices even when the source is not `static`.

OpenCost, and some agents, re-export kube-state-metrics series under their own job. The rules deduplicate them (`max without (job, instance, …)`), so installing OpenCost next to kube-state-metrics does not count requests or capacity twice.

## Install

```bash
helm repo add oreonit https://oreondev.github.io/helm-charts
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
| `excludeNamespaces` | `kube-.*\|gmp-.*\|gke-.*\|monitoring\|kyverno` | System namespaces: the alerts, the headline waste figure and the savings levers leave them out |
| `pricing.currency` | `USD` | `USD`, `GBP` or `EUR` (dashboard unit) |
| `pricing.cpuCoreHour` | `0.032` | Price of one vCPU-hour |
| `pricing.memoryGiBHour` | `0.0043` | Price of one GiB-hour |
| `pricing.source` | `static` | `static`, `instanceType` or `opencost` (see Pricing sources) |
| `pricing.instanceTypes` | `{}` | On-demand $/hour per instance type (`instanceType` source) |
| `pricing.spotDiscount` | `0.65` | Discount of spot on on-demand: prices spot nodes (`instanceType`) and the spot lever |
| `pricing.storageGiBMonth` / `loadBalancerHour` | `0.10` / `0.025` | Prices for the idle-volume and idle-load-balancer levers |
| `savings.spotEligibleShare` | `0.5` | Share of on-demand node spend that could run on spot |
| `savings.commitmentDiscount` | `0.3` | Discount of a 1-year commitment on the 7-day minimum of on-demand spend |
| `savings.idleHeadroom` | `0.2` | Share of unrequested capacity kept as headroom (not counted as saveable) |
| `thresholds.cpuWasteRatio` / `memoryWasteRatio` | `0.7` | Unused share of requests that triggers the over-requested alerts |
| `thresholds.minCpuRequestCores` / `minMemoryRequestGiB` | `2` / `4` | Ignore namespaces requesting less than this |
| `thresholds.clusterCpuCommitRatio` / `clusterMemoryCommitRatio` | `0.4` | Under-committed threshold |
| `alerts.<name>.enabled` / `severity` / `for` | see table | Per-alert switches |
| `alertLabels` | `{}` | Labels added to every alert (team, routing) |

## How to read it

- **Over-requested namespaces** are the usual first win: memory requests set "to be safe" decide how many nodes you pay for. Right-size with VPA recommendations, then let the autoscaler remove nodes.
- **Under-committed cluster** with over-requested namespaces means both problems at once: fix requests first, then node pool minimums and machine types.
- **Prices** are a model, not an invoice. OpenCost gets you list prices per node; discounts you already have (Savings Plans, CUDs, enterprise agreements) are not in them, so the commitment lever overstates the saving if a commitment already covers the baseline.
- **Unrequested capacity** only turns into savings when nodes go away: right-size requests first, then let the autoscaler or Karpenter consolidate.
- `UnusedLoadBalancerService` needs kube-state-metrics 2.6 or newer (`kube_endpoint_address`); on older versions it stays silent rather than guessing.

Background: [GKE cost optimisation levers](https://www.oreonit.com/gke-cost-optimization-levers-that-work/), [EKS cost optimisation](https://www.oreonit.com/eks-cost-optimization-12-levers-that-actually-work/), [cost observability and FinOps](https://www.oreonit.com/cost-observability-finops/). If you want the findings turned into a prioritised savings plan with the changes made, that is the [cloud cost optimisation review](https://www.oreonit.com/cloud-cost-optimization-review/).

## Licence

MIT. Maintained by [Oreon IT](https://www.oreonit.com/).
