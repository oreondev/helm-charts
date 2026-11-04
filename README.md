# Oreon IT Helm charts

[![Artifact Hub](https://img.shields.io/endpoint?url=https://artifacthub.io/badge/repository/oreonit)](https://artifacthub.io/packages/search?repo=oreonit)
[![Release](https://github.com/oreondev/helm-charts/actions/workflows/release.yml/badge.svg)](https://github.com/oreondev/helm-charts/actions/workflows/release.yml)
[![Licence: MIT](https://img.shields.io/badge/licence-MIT-blue.svg)](LICENSE)

Charts we install on client clusters, published so you can use them too. None of them installs Prometheus, Grafana, Kyverno or Velero: each one packages the configuration that teams otherwise hand-write on top of those tools. The exceptions are the application charts: crawl4ai, evolution, firecrawl and mem0. Where upstream publishes no usable image (or a bloated one), the image is built here from the upstream release ([images](images)).

| Chart | What it does | Needs |
|---|---|---|
| [alertmanager-routing-baseline](charts/alertmanager-routing-baseline) | Teams, page/ticket receivers (Slack, PagerDuty, Opsgenie, email, Teams, webhook), severity routing, inhibition, business-hours muting, Watchdog sink, as an AlertmanagerConfig. | Prometheus Operator |
| [blackbox-slo-probes](charts/blackbox-slo-probes) | URLs become Probe objects plus availability and latency SLOs with the same burn-rate alerts, probe-down and TLS-expiry alerts, and a dashboard. | blackbox exporter, Prometheus Operator |
| [crawl4ai](charts/crawl4ai) | Crawl4AI web crawler for LLMs (REST and MCP) tuned for production: gunicorn as PID 1, Redis as a native sidecar or external for horizontal scaling, generated API token and JWT key, shutdown in seconds, memory threshold below the OOM line, security flags off, non-root read-only, ServiceMonitor with bearer auth, alerts and dashboard. | nothing (external Redis to scale out) |
| [evolution](charts/evolution) | Evolution API (WhatsApp) tuned for production: migrations in an init container, single replica with Recreate, heap cap from the memory limit, non-root read-only, probes that do not call WhatsApp, Redis-backed sessions without a volume, generated API key, Ingress or HTTPRoute, metrics, ServiceMonitor and alerts. | PostgreSQL or MySQL, Redis |
| [firecrawl](charts/firecrawl) | Firecrawl scraping API for LLMs in production: one Deployment per component (API, crawl and scrape workers, Playwright), token gate in front of the unauthenticated API, queue schema Job that works on managed PostgreSQL (pg_cron), WAL sized for the volume, KEDA scaling on queue depth, pinned digests, non-root read-only, NetworkPolicy, PodMonitor, alerts and dashboard. | nothing (PostgreSQL with pg_cron and Redis to run them yourself) |
| [gateway-api-baseline](charts/gateway-api-baseline) | Shared Gateway API ingress: one Gateway with HTTP-to-HTTPS redirect and TLS listeners per hostname, namespace-scoped attachment, HTTPRoutes/GRPCRoutes from values with timeouts and security headers, generated ReferenceGrants, default backend, BackendTLSPolicies. | Gateway API CRDs + any controller (GKE, Envoy Gateway, NGINX Gateway Fabric, Istio, Cilium) |
| [k8s-cost-waste-alerts](charts/k8s-cost-waste-alerts) | Cluster cost and showback per namespace (node prices from flat rates, an instance-type price list or OpenCost), requests vs usage priced per month, unrequested node capacity, savings levers (right-sizing, consolidation, spot, commitments), idle PVCs and LoadBalancers, HPAs at max or pinned. Rules and a dashboard. | kube-state-metrics, cAdvisor |
| [kyverno-production-policies](charts/kyverno-production-policies) | The production readiness checklist as Kyverno policies: requests/limits, probes, labels, no latest tags, PDBs and spread for multi-replica workloads, no NodePorts, nothing in default. Audit mode first. | Kyverno 1.13+ |
| [llm-serving-observability](charts/llm-serving-observability) | Alerts, recording rules and dashboards for self-hosted LLM serving: vLLM (queue, KV cache, preemptions, errors, time to first token, inter-token latency, tokens/s) and NVIDIA GPUs via DCGM (XID errors, row remap failures, temperature, memory, GPUs assigned but idle), optional PodMonitors, SLO examples. | Prometheus Operator, vLLM and/or dcgm-exporter |
| [mem0](charts/mem0) | Mem0 memory server and dashboard for AI agents: images built from the upstream release (pinned, non-root, read-only), databases, pgvector, migrations and first admin in init containers, probes that skip the request log, log-pruning CronJob, OpenAI-compatible endpoints for private models, Ingress or HTTPRoute, metrics on a separate port, alerts and dashboard. | PostgreSQL with pgvector |
| [namespace-baseline](charts/namespace-baseline) | Guardrails per team namespace: Pod Security Admission labels, ResourceQuota, LimitRange, default-deny NetworkPolicies with the usual allows, RBAC bindings, optional quota alerts. | a CNI that enforces NetworkPolicy |
| [otel-collector-baseline](charts/otel-collector-baseline) | OpenTelemetry Collector layout: node agent (OTLP, kubelet and host metrics, container logs, Kubernetes metadata) feeding a gateway (health-check filtering, redaction, tail sampling) that exports to OTLP, Google Cloud, Prometheus remote write, Datadog or Elasticsearch; auto-instrumentation, RBAC, alerts, dashboard. | OpenTelemetry Operator |
| [searxng](charts/searxng) | SearXNG metasearch as the search backend for LLM tools and agents (JSON API mode, curated engines, stable secret key, NetworkPolicy allow list) or a public instance (rate limiter with a Valkey sidecar), non-root read-only, per-engine metrics, alerts and dashboard. | nothing |
| [slo-burn-rate-alerts](charts/slo-burn-rate-alerts) | SLOs as values: recording rules, multi-window multi-burn-rate page/ticket alerts and an SLO dashboard. Prometheus Operator or Google Managed Prometheus backends. | Prometheus Operator / GMP, Grafana sidecar |
| [text-embeddings-inference](charts/text-embeddings-inference) | Hugging Face Text Embeddings Inference: several embedding, reranker and classifier models per release on CPU or NVIDIA GPUs (image variant from the accelerator), model cache kept across restarts, generated API key, non-root read-only, OpenAI-compatible /v1/embeddings, KEDA on the request queue, alerts and dashboard. | GPU nodes for large models (optional) |
| [velero-backup-schedules](charts/velero-backup-schedules) | Daily/weekly/monthly Velero Schedules with retention, optional storage locations, a scheduled restore test into a scratch namespace, and backup alerts. | Velero |

## Use

```bash
helm repo add oreonit https://oreondev.github.io/helm-charts
helm repo update
helm search repo oreonit
```

The charts are also listed on [Artifact Hub](https://artifacthub.io/packages/search?repo=oreonit).

## Versions and releases

[CHANGELOG.md](CHANGELOG.md) lists every chart's current version and what changed in each release. Every change to a chart bumps its `version` (patch for fixes, minor for features or changed defaults, major when an upgrade needs action) and adds an `artifacthub.io/changes` entry; the release workflow publishes any chart whose version changed.

Application charts follow an upstream project. The [upstream-releases](.github/workflows/upstream-releases.yml) workflow checks them weekly against [.github/upstream.yaml](.github/upstream.yaml) and opens an issue when one is behind (`python3 .github/scripts/check-upstream.py` runs the same check locally). Where upstream publishes no usable image, it is built in [images/](images) by the [images](.github/workflows/images.yml) workflow: amd64 and arm64, Trivy scan, pushed to `ghcr.io/oreondev/<app>-<name>` with cosign keyless signatures, rebuilt weekly for base image fixes.

## Develop

```bash
helm lint charts/slo-burn-rate-alerts -f charts/slo-burn-rate-alerts/ci/test-values.yaml
helm template slo charts/slo-burn-rate-alerts -f charts/slo-burn-rate-alerts/ci/test-values.yaml
```

Pull requests run [chart-testing](https://github.com/helm/chart-testing) (lint, then install on a kind cluster with the CRDs the charts target: Prometheus Operator, Google Managed Prometheus, Kyverno, Velero, Gateway API, OpenTelemetry Operator). The charts' custom resources are created but nothing reconciles them there; behaviour on a real cluster is tested by hand before a release. Pushes to `main` that change a chart version are packaged and published to the `gh-pages` branch by [chart-releaser](https://github.com/helm/chart-releaser), which also updates `index.yaml`.

### First-time publishing checklist

1. Create an empty `gh-pages` branch once: `git checkout --orphan gh-pages && git rm -rf . && git commit --allow-empty -m "gh-pages" && git push origin gh-pages && git checkout main`.
2. Repository settings, Pages: source = branch `gh-pages`, folder `/`.
3. Push `main`; the release workflow creates a GitHub release per chart and the Helm index at `https://oreondev.github.io/helm-charts/index.yaml`.
4. On Artifact Hub, add a Helm repository with that URL. Paste the repository ID it shows into `artifacthub-repo.yml` (the workflow copies the file to `gh-pages`) to get the verified-publisher badge.

## Contributing

Issues and pull requests are welcome. Keep charts CRD-free where possible, keep `values.schema.json` in step with `values.yaml`, bump `version` in `Chart.yaml` for every change (the release workflow keys on it).

## Licence

MIT. Maintained by [Oreon IT](https://www.oreonit.com/), a DevOps, SRE and cloud consultancy in London. If you want [SLOs defined](https://www.oreonit.com/site-reliability-engineering-sre-consulting-services/), a [multi-team Kubernetes platform](https://www.oreonit.com/containerization-orchestration-management-kubernetes-openshift/) or a [tested disaster recovery plan](https://www.oreonit.com/disaster-recovery-planning-services/) built with you, that is the day job.
