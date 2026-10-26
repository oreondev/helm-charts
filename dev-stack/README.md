# Dev stack

The controllers the charts in this repo target, sized for one test node, so
every chart can be installed against the real thing and watched in Grafana.

| Phase | What | Used by |
|---|---|---|
| `monitoring` | kube-prometheus-stack (Prometheus, Alertmanager, Grafana, kube-state-metrics, node-exporter), cert-manager, OpenTelemetry Operator, blackbox exporter | slo-burn-rate-alerts, alertmanager-routing-baseline, k8s-cost-waste-alerts, blackbox-slo-probes, otel-collector-baseline, namespace-baseline |
| `policy` | Kyverno | kyverno-production-policies |

Not included: Velero (needs object storage) and a Gateway API controller.

## Use

```sh
export KUBECONFIG=...                      # a throwaway cluster
DEV_STACK_CONTEXT=$(kubectl config current-context) ./dev-stack/install.sh all

# demo service with request metrics, plus a webhook sink that logs alert deliveries
kubectl apply -f dev-stack/demo-app.yaml -f dev-stack/alert-sink.yaml

helm upgrade --install slo charts/slo-burn-rate-alerts -n monitoring -f dev-stack/slo-burn-rate-alerts.yaml
helm upgrade --install routing charts/alertmanager-routing-baseline -n monitoring -f dev-stack/alertmanager-routing-baseline.yaml
helm upgrade --install otel charts/otel-collector-baseline -n observability --create-namespace -f dev-stack/otel-collector-baseline.yaml
helm upgrade --install policies charts/kyverno-production-policies -n kyverno -f dev-stack/kyverno-production-policies.yaml
```

The script refuses to run unless `DEV_STACK_CONTEXT` names the current
context, and it deletes CRDs that a chart wants to own, so keep it off real
clusters.

## Drive it

```sh
kubectl -n demo set env deploy/load ERROR_PERCENT=20   # burn error budget; SLOBurnRatePage fires in ~3 min
kubectl -n demo set env deploy/load ERROR_PERCENT=0    # recover
kubectl -n monitoring logs deploy/alert-sink -f        # which receiver got which alert
kubectl -n monitoring port-forward svc/kube-prometheus-stack-grafana 3000:80
kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090:9090
```

Traces: run telemetrygen against the node-local collector Service.

```sh
kubectl run tgen --rm -it --restart=Never \
  --image=ghcr.io/open-telemetry/opentelemetry-collector-contrib/telemetrygen:v0.163.0 -- \
  traces --otlp-endpoint=otel-agent-local.observability.svc:4317 --otlp-insecure --traces=50
```

Route alerts by a `team` label, not by namespace: SLO alerts are built from
cluster-wide sums and carry no namespace label.
