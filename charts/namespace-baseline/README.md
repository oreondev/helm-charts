# namespace-baseline

The guardrails every team namespace should have, from one values file:

| Resource | What it enforces |
|---|---|
| `Namespace` with Pod Security Admission labels | `baseline` enforced, `restricted` warned and audited by default; per namespace override |
| `ResourceQuota` | CPU, memory, pods, PVCs, LoadBalancers per namespace |
| `LimitRange` | default requests and limits, so nothing runs without them; min/max per container; PVC max |
| `NetworkPolicy` x up to 6 | default deny ingress and egress, then allow: same namespace, DNS, listed namespaces in, listed namespaces out, listed CIDRs out |
| `RoleBinding` x up to 3 | groups (or users, service accounts) bound to the built-in `admin`, `edit`, `view` ClusterRoles |
| `PriorityClass` (cluster-wide, optional) | tenant-critical / tenant-batch style classes |
| `PrometheusRule` (optional) | alerts at 90 % and 100 % of any quota, from kube-state-metrics |

It is the chart we install first on every multi-team cluster, instead of copying twenty YAML files per namespace. Defaults are deliberately conservative; override per namespace.

## Install

```bash
helm repo add oreonit https://oreondev.github.io/helm-charts
helm repo update
helm install baseline oreonit/namespace-baseline -n platform --create-namespace -f namespaces.yaml
```

`namespaces.yaml`:

```yaml
defaults:
  networkPolicy:
    allowIngressFromNamespaces: [ingress-nginx, monitoring]
  rbac:
    viewers: [sre-oncall]

namespaces:
  - name: team-payments
    podSecurity:
      enforce: restricted
    quota:
      hard:
        requests.cpu: "16"
        requests.memory: 32Gi
        limits.cpu: "32"
        limits.memory: 64Gi
        pods: "200"
    networkPolicy:
      allowEgressToNamespaces: [shared-db]
      allowEgressCIDRs:
        - cidr: 0.0.0.0/0
          except: [10.0.0.0/8, 169.254.169.254/32]
          ports: [{port: 443, protocol: TCP}]
    rbac:
      admins: [platform-team]
      editors: [payments-developers]

  - name: team-sandbox
    networkPolicy:
      enabled: false
```

`defaults` is merged into each namespace entry: maps merge key by key, lists are replaced. Everything in `defaults` can be overridden per namespace.

## Values

| Key | Default | Description |
|---|---|---|
| `defaults.create` | `true` | Create the Namespace (false = resources only, in a namespace you manage elsewhere) |
| `defaults.keepOnUninstall` | `true` | Annotate the Namespace with `helm.sh/resource-policy: keep` |
| `defaults.labels`, `annotations` | `{}` | Extra Namespace metadata |
| `defaults.podSecurity.enabled` | `true` | Manage the PSA labels |
| `defaults.podSecurity.enforce` / `audit` / `warn` | `baseline` / `restricted` / `restricted` | PSA levels |
| `defaults.podSecurity.enforceVersion` | `latest` | PSA version pin |
| `defaults.quota.enabled` | `true` | Create the ResourceQuota |
| `defaults.quota.hard` | 4 CPU / 8Gi requests, 8 CPU / 16Gi limits, 50 pods, 10 PVCs, 0 LoadBalancers | Quota map, passed through as-is |
| `defaults.limitRange.enabled` | `true` | Create the LimitRange |
| `defaults.limitRange.container` | 50m/64Mi request, 500m/512Mi limit, min 10m/16Mi, max 4/8Gi | `defaultRequest`, `default`, `min`, `max`, `maxLimitRequestRatio` |
| `defaults.limitRange.pod` | unset | `min`, `max`, `maxLimitRequestRatio` |
| `defaults.limitRange.pvc` | max 100Gi | `min`, `max` |
| `defaults.networkPolicy.enabled` | `true` | Create NetworkPolicies |
| `defaults.networkPolicy.defaultDeny` | `true` | Deny all ingress and egress first |
| `defaults.networkPolicy.allowSameNamespace` | `true` | Pods in the namespace can talk to each other |
| `defaults.networkPolicy.allowDNS` | kube-system / `k8s-app: kube-dns` | Egress to cluster DNS on 53 |
| `defaults.networkPolicy.allowIngressFromNamespaces` | `[]` | Names, or `{namespace, podLabels, ports}` |
| `defaults.networkPolicy.allowEgressToNamespaces` | `[]` | Same shape |
| `defaults.networkPolicy.allowEgressCIDRs` | `[]` | `{cidr, except, ports}` |
| `defaults.rbac.enabled` | `true` | Create RoleBindings |
| `defaults.rbac.admins` / `editors` / `viewers` | `[]` | Group names, or `{kind, name, namespace}` |
| `namespaces[]` | `[]` | `name` plus any override of the keys above |
| `priorityClasses[]` | `[]` | `name`, `value`, `globalDefault`, `preemptionPolicy`, `description` |
| `monitoring.enabled` | `false` | PrometheusRule for quota usage |
| `monitoring.labels` | `{}` | Prometheus Operator ruleSelector labels |
| `monitoring.nearLimitThreshold` | `0.9` | Warning threshold |

## Things to know

- **NetworkPolicy needs a CNI that enforces it.** GKE: Dataplane V2 or "network policy" enabled. EKS: VPC CNI with network policy enabled, or Calico/Cilium. AKS: Azure NPM or Cilium. kind/minikube default CNIs ignore policies silently.
- **NodeLocal DNSCache.** If DNS goes to the node-local IP (GKE and EKS add-ons), add it to `allowEgressCIDRs`, e.g. `{cidr: 169.254.20.10/32, ports: [{port: 53, protocol: UDP}, {port: 53, protocol: TCP}]}`.
- **Existing namespaces.** Helm refuses to overwrite objects it does not own. Either set `create: false` for that namespace, or let Helm adopt it first:
  ```bash
  kubectl label ns team-x app.kubernetes.io/managed-by=Helm
  kubectl annotate ns team-x meta.helm.sh/release-name=baseline meta.helm.sh/release-namespace=platform
  ```
- **Uninstall is safe by default.** Namespaces carry `helm.sh/resource-policy: keep`, so `helm uninstall` removes quotas, policies and bindings but leaves the namespaces and workloads. Set `keepOnUninstall: false` for throwaway namespaces.
- **PSA `restricted`** rejects pods that run as root, without a seccomp profile, or with added capabilities. Start with `enforce: baseline` and `warn: restricted`, fix the warnings, then move `enforce` up.
- **Quota and LimitRange interplay.** With a LimitRange default request in place, pods without requests still count against the quota, which is the point; without one, such pods are rejected by the quota admission.

Background: [Kubernetes production readiness checklist](https://www.oreonit.com/kubernetes-production-readiness-checklist/). If you would rather have the tenancy model designed and rolled out for you, see our [Kubernetes consulting](https://www.oreonit.com/containerization-orchestration-management-kubernetes-openshift/).

## Licence

MIT. Maintained by [Oreon IT](https://www.oreonit.com/).
