# otel-collector-baseline

The OpenTelemetry Collector layout we run on client clusters, as values for the [OpenTelemetry Operator](https://github.com/open-telemetry/opentelemetry-operator). The operator does the deploying; this chart says what the collectors are and what they do.

```
pods ──OTLP──▶ agent (DaemonSet, one per node)        ──OTLP──▶ gateway (Deployment)         ──▶ backends
               otlp, kubeletstats, hostmetrics, filelog           drop health checks, redact,       OTLP / OTLP-HTTP
               k8sattributes, resourcedetection, resource         tail sampling, batch               Google Cloud
               memory_limiter, batch                                                                 Prometheus remote write
                                                                                                     Datadog, Elasticsearch
```

- **Agent**: receives OTLP from the pods on its node (through a node-local Service, so traffic never crosses nodes), scrapes the kubelet (node, pod, container, volume metrics) and the host (CPU, memory, disk, filesystem, load, network), tails container logs with checkpointing, and enriches everything with Kubernetes metadata and the labels you choose.
- **Gateway**: the only place that holds backend credentials. Filters health-check spans, deletes sensitive attributes, optionally tail-samples (every error and every slow trace kept, a percentage of the rest; agents route by trace ID so a trace lands on one replica), batches, exports. Replicas or an autoscaler, with a PodDisruptionBudget.
- **Backends**: enable any number and say which signals each takes. Credentials are `${env:NAME}` references resolved from `gateway.env`.
- **Instrumentation**: one `Instrumentation` object for the operator's auto-instrumentation (Java, Node.js, Python, .NET, Go), pointing at the node-local agent.
- **Monitoring**: operator-generated ServiceMonitors, a PrometheusRule (export failures, full queues, refused data, dropped data, unavailable pods, restarts) and a Grafana dashboard.
- **RBAC** for the k8sattributes and kubeletstats receivers.

With no backend enabled everything goes to the `debug` exporter, so a fresh install shows data moving in the gateway log before you commit to a destination.

## Install

```bash
helm repo add oreonit https://oreonit.github.io/helm-charts
helm install otel oreonit/otel-collector-baseline -n observability --create-namespace -f otel.yaml
```

`otel.yaml`, Grafana Cloud over OTLP:

```yaml
clusterName: prod-eu
environment: production

gateway:
  env:
    - name: GRAFANA_CLOUD_AUTH          # base64 of "<instance id>:<token>"
      valueFrom: {secretKeyRef: {name: grafana-cloud, key: auth}}

backends:
  otlphttp:
    enabled: true
    endpoint: https://otlp-gateway-prod-eu-west-2.grafana.net/otlp
    headers:
      Authorization: "Basic ${env:GRAFANA_CLOUD_AUTH}"

processing:
  tailSampling:
    enabled: true
    percentage: 10

instrumentation:
  enabled: true

monitoring:
  enabled: true
  labels:
    release: kube-prometheus-stack
```

Google Cloud (Cloud Trace, Cloud Logging, Managed Service for Prometheus) with Workload Identity on the gateway's ServiceAccount:

```yaml
clusterName: prod-gke
image: otel/opentelemetry-collector-contrib:0.163.2     # contrib carries the Google exporters
agent:
  receivers:
    filelog:
      enabled: false                                     # GKE already ships container logs
  resourceDetectors: [env, gcp]
backends:
  googlecloud:
    enabled: true
  googlemanagedprometheus:
    enabled: true
```

Then instrument an app without touching its image:

```bash
kubectl -n shop patch deployment checkout -p \
  '{"spec":{"template":{"metadata":{"annotations":{"instrumentation.opentelemetry.io/inject-java":"observability/otel"}}}}}'
```

Check:

```bash
kubectl -n observability get opentelemetrycollectors
kubectl -n observability logs deploy/otel-gateway-collector --tail=50
```

## Values

| Key | Default | Description |
|---|---|---|
| `clusterName` | `""` (required) | `k8s.cluster.name` on everything |
| `environment` | `""` | `deployment.environment.name` |
| `image` | `""` | Collector image; empty = operator default. Contrib needed for Google, Datadog, Elasticsearch |
| `telemetry.{metricsPort,level,logLevel,readers}` | 8888 / normal / info / true | Collector self-telemetry; `readers: false` for collectors older than 0.123 |
| `agent.enabled` | `true` | Node agent DaemonSet |
| `agent.receivers.otlp.enabled` | `true` | OTLP gRPC 4317 and HTTP 4318 |
| `agent.receivers.kubeletstats.*` | on, 30s, node/pod/container/volume | Kubelet metrics |
| `agent.receivers.hostmetrics.*` | on, 30s, cpu/memory/disk/filesystem/load/network | Host metrics from `/hostfs` |
| `agent.receivers.filelog.*` | on, checkpointed at `/var/lib/otelcol/filelog` | Container logs; `excludeNamespaces`, `startAt` |
| `agent.k8sattributes.{extractMetadata,extractLabels,extractAnnotations}` | see values.yaml | Kubernetes metadata and label/annotation copies |
| `agent.resourceDetectors` | `[env]` | Add `gcp`, `eks`, `ec2`, `aks`, `azure` |
| `agent.{memoryLimiter,batch,resources,tolerations,nodeSelector,priorityClassName,podAnnotations,securityContext,env,extraVolumes,extraVolumeMounts}` | | Workload settings; tolerates every taint by default |
| `agent.extraConfig` / `agent.extraSpec` | `{}` | Deep-merged into the collector config / the OpenTelemetryCollector spec |
| `gateway.enabled` | `true` | Gateway Deployment; off = the agent exports straight to the backends |
| `gateway.{replicas,autoscaler,podDisruptionBudget}` | 2 / off / minAvailable 1 | Scale and availability |
| `gateway.{memoryLimiter,batch,resources,tolerations,nodeSelector,affinity,topologySpreadConstraints,priorityClassName,podAnnotations,env,extraVolumes,extraVolumeMounts,extraConfig,extraSpec}` | | Workload settings; `env` carries the backend secrets |
| `processing.dropHealthChecks.{enabled,paths}` | on, `/healthz` `/readyz` `/livez` `/health` `/ready` `/live` `/metrics` `/ping` | Filter spans by `url.path`, `http.route`, `http.target` |
| `processing.tailSampling.{enabled,decisionWait,numTraces,errorsAlways,slowMs,percentage,extraPolicies}` | off, 10s, 100000, true, 2000, 10 | Tail sampling in the gateway |
| `processing.redact.{enabled,attributes,patterns}` | on, auth/cookie/api-key headers | Attributes deleted from spans and logs |
| `processing.resourceAttributes` | `{}` | Extra resource attributes on everything |
| `backends.otlp` / `backends.otlphttp` | off | `endpoint`, `headers`, `tls`, `compression`, `signals` |
| `backends.googlecloud` | off | `project`, `signals` (traces, logs) |
| `backends.googlemanagedprometheus` | off | `project`; metrics |
| `backends.prometheusremotewrite` | off | `endpoint`, `headers`, `tls`, `resourceToTelemetryConversion`; metrics |
| `backends.datadog` | off | `site`, `apiKey`, `signals` |
| `backends.elasticsearch` | off | `endpoints`, `apiKey`, `mappingMode`, `tls`, `signals` |
| `backends.debug` | off | `verbosity`, `signals` |
| `instrumentation.{enabled,name,namespace,endpoint,propagators,sampler,resourceAttributes,env,java,nodejs,python,dotnet,go}` | off | Instrumentation object |
| `monitoring.{enabled,labels,serviceMonitor,prometheusRule,dashboard,alerts}` | off | Prometheus Operator and Grafana sidecar integration |

## Notes

- The operator names the workloads and Services `<name>-collector`; the chart's names are `<release>-agent` and `<release>-gateway`. The node-local Service `<release>-agent-local` selects the agent pods by the labels the operator puts on them (`app.kubernetes.io/instance: <namespace>.<name>`, `app.kubernetes.io/component: opentelemetry-collector`) with `internalTrafficPolicy: Local`.
- The health-check filter drops matching spans only; a child span of a health check (a DB ping, say) stays and shows as an orphan. Add the route to `processing.redact` or widen `paths` if that bothers you.
- Collector internal metric names gained a `_total` suffix on counters when the collector moved to the OpenTelemetry SDK for its own telemetry. The alerts and the dashboard match both spellings.
- Reading `/var/log/pods` needs root, so the agent runs as uid 0 when `filelog` is on and no `securityContext` is given. Namespaces under the `restricted` Pod Security Standard reject that: use `privileged` for the collector namespace, as every log agent needs.
- Tail sampling only works when whole traces reach one process, which is why it lives in the gateway and why agents switch to the `loadbalancing` exporter (routing by trace ID to the gateway's headless Service) when it is on. Size `numTraces` × average trace size against the gateway memory limit.
- `monitoring.labels` go on the OpenTelemetryCollector objects, which the operator propagates to the ServiceMonitors it creates, and on the PrometheusRule. kube-prometheus-stack needs its `release` label there unless its `*SelectorNilUsesHelmValues` flags are off.
- For Prometheus scraping of annotated pods use the operator's target allocator with a prometheus receiver; this chart deliberately stays with OTLP, kubelet, host and logs. Our [slo-burn-rate-alerts](../slo-burn-rate-alerts) and [blackbox-slo-probes](../blackbox-slo-probes) charts sit on the metrics this one ships.

The agent and gateway split, the sampling policy and the redaction list are the shape we describe in [10 observability metrics every DevOps engineer should track](https://www.oreonit.com/10-essential-observability-metrics-every-devops-engineer-should-track/) and [how to avoid alert fatigue](https://www.oreonit.com/advanced-alerting-strategies-how-to-avoid-alert-fatigue-in-monitoring-systems/). If you would like the pipeline designed around your backends and budget, see our [observability consulting](https://www.oreonit.com/observability-and-monitoring-consultancy-services/).

## Licence

MIT. Maintained by [Oreon IT](https://www.oreonit.com/).
