# llm-serving-observability

Alerts, recording rules and Grafana dashboards for self-hosted LLM serving on Kubernetes: [vLLM](https://github.com/vllm-project/vllm) and the NVIDIA GPUs under it, read through [dcgm-exporter](https://github.com/NVIDIA/dcgm-exporter) as the NVIDIA GPU Operator installs it. It installs no exporter and no Prometheus. Like the other charts in this repository, it packages the monitoring that teams otherwise write by hand on top of kube-prometheus-stack.

**vLLM**

| Alert | Fires when |
|---|---|
| `VLLMServerDown` / `VLLMNoTargets` | a vLLM scrape fails, or no vLLM server is scraped at all (pods deleted, evicted, unschedulable for lack of GPUs) |
| `VLLMRequestsQueued` | requests wait for a slot (`vllm:num_requests_waiting`) |
| `VLLMKVCacheFull` | KV cache above 95%: requests are about to be preempted |
| `VLLMPreemptions` | preempted requests per minute; they are recomputed from scratch |
| `VLLMRequestErrors` | share of requests finishing with `finished_reason="error"` |
| `VLLMSlowTimeToFirstToken` / `VLLMSlowTokenGeneration` | p95 time to first token, p95 inter-token latency |

**NVIDIA GPUs (DCGM)**

| Alert | Fires when |
|---|---|
| `GPUXidError` | any XID error: driver, ECC or hardware fault (79 = fell off the bus); `gpu.alerts.xid.ignore` for codes you expect |
| `GPURowRemapFailure` | memory fault the GPU can no longer work around: replace the card or node |
| `GPUHot`, `GPUMemoryFull` | temperature and framebuffer memory |
| `GPUAllocatedIdle` | a GPU assigned to a pod but under 5% busy for 2 hours, the most expensive idle resource in a cluster (info) |

Recording rules (`llm:vllm_*`, `llm:gpu_*`) give per-model request and token rates, error ratio, p95 TTFT, inter-token and end-to-end latency, queue, KV cache and prefix-cache hit ratio, plus per-GPU utilisation and memory and counts of GPUs and assigned GPUs. Two dashboards, **vLLM serving** and **GPUs for LLM serving**, are built on them.

Metric names and labels were checked against vLLM 0.32.0 (`vllm/v1/metrics/loggers.py`) and dcgm-exporter's default counters, then tested twice on a kind cluster:
- **Real vLLM:** the official CPU image (`vllm/vllm-openai-cpu:v0.32.0`) serving `facebook/opt-125m` under load, scraped through the chart's PodMonitor. All 10 vLLM recording rules and all 18 queries on the vLLM dashboard returned data, `VLLMServerDown` (during a model reload) and `VLLMSlowTokenGeneration` fired with shortened `for` and a lower threshold, and `VLLMSlowTimeToFirstToken` went pending at its default 2 s under load.
- **Exporters emitting the exact series** forced the other conditions (queue, KV cache, preemptions, errors and every GPU alert): 12 of the 13 alerts fired with the right labels and summaries, the idle-GPU alert ignored an unassigned GPU, and every GPU dashboard query returned data. No real GPU was involved.

## Install

```bash
helm repo add oreonit https://oreondev.github.io/helm-charts
helm install llm-obs oreonit/llm-serving-observability -n monitoring -f llm-obs.yaml
```

```yaml
prometheusRule:
  labels: { release: kube-prometheus-stack }

vllm:
  matchers: 'namespace="ai"'             # optional: only these vLLM servers
gpu:
  matchers: 'Hostname=~"gke-gpu-.*"'     # optional

# Only if nothing scrapes them yet:
scrape:
  vllm:
    enabled: true
    labels: { release: kube-prometheus-stack }
    selector:
      matchLabels: { app.kubernetes.io/name: vllm }
  dcgm:
    enabled: true                        # the GPU Operator's own ServiceMonitor is the usual way
    labels: { release: kube-prometheus-stack }
```

Two scrape details matter:
- **vLLM:** the vLLM rules read `up{job=~".*vllm.*"}` (`vllm.upMatcher`). Match it to how your scrape names the job.
- **Model load time:** a vLLM pod does not answer scrapes while it loads the model, so `VLLMServerDown` fires if `vllm.alerts.down.for` (5m) is shorter than your load time. Raise it for large models.
- **DCGM:** dcgm-exporter labels each GPU with the namespace and pod using it. The scrape has to keep those labels (`honorLabels`) and not attach the exporter pod's own; the chart's PodMonitor does both. Otherwise every idle GPU looks assigned to the exporter.

### SLOs on time to first token and errors

The [slo-burn-rate-alerts](../slo-burn-rate-alerts) chart turns these metrics into SLOs with multi-window burn-rate alerts and an error-budget dashboard. vLLM's TTFT histogram has buckets at 0.25, 0.5, 0.75, 1 and 2.5 s, so pick one of those as the threshold:

```yaml
slos:
  - name: chat-ttft
    service: qwen3-8b
    objective: 95                         # 95% of requests get a first token within 1 s
    description: Time to first token at most 1 s
    sli:
      errorQuery: |
        sum(rate(vllm:time_to_first_token_seconds_count{model_name="Qwen/Qwen3-8B"}[$WINDOW]))
          - sum(rate(vllm:time_to_first_token_seconds_bucket{model_name="Qwen/Qwen3-8B", le="1.0"}[$WINDOW]))
      totalQuery: sum(rate(vllm:time_to_first_token_seconds_count{model_name="Qwen/Qwen3-8B"}[$WINDOW]))
  - name: chat-availability
    service: qwen3-8b
    objective: 99.5
    description: Requests not ending in a server error
    sli:
      errorQuery: sum(rate(vllm:request_success_total{model_name="Qwen/Qwen3-8B", finished_reason="error"}[$WINDOW]))
      totalQuery: sum(rate(vllm:request_success_total{model_name="Qwen/Qwen3-8B"}[$WINDOW]))
```

### Embeddings

Embedding and reranker servers have their own alerts and dashboard in the [text-embeddings-inference](../text-embeddings-inference) chart.

### Running vLLM on Kubernetes: two gotchas we hit while testing

- **Name the Service something other than `vllm`, or set `enableServiceLinks: false`.** Kubernetes injects `VLLM_PORT=tcp://...` for a Service called `vllm`, and vLLM reads `VLLM_PORT` as its own setting and refuses to start.
- **Give the pod a bigger `/dev/shm`.** The container default (64 MiB) is too small and the engine fails with "Insufficient space in /dev/shm". Mount an `emptyDir` with `medium: Memory` at `/dev/shm`.

## Values

| Key | Default | |
|---|---|---|
| `prometheusRule.enabled` / `.namespace` / `.labels` / `.interval` | on / release ns / / 30s | |
| `dashboards.enabled` / `.namespace` / `.labels` / `.annotations` | on / / `grafana_dashboard: "1"` | |
| `scrape.vllm.*`, `scrape.dcgm.*` | off | PodMonitors |
| `vllm.enabled` / `.matchers` / `.upMatcher` / `.ignoreModels` | on / / `job=~".*vllm.*"` / | |
| `vllm.alerts.<alert>.enabled` / thresholds / `for` | see values.yaml | queue 10, KV 95%, preemptions 1/min, errors 2%, TTFT 2 s, ITL 0.2 s |
| `gpu.enabled` / `.matchers` | on | |
| `gpu.alerts.<alert>.*` | see values.yaml | 85 °C, memory 95%, idle < 5% for 2 h |

Everything is validated by `values.schema.json`.

## Licence

MIT. Maintained by [Oreon IT](https://www.oreonit.com/?utm_source=helm-chart&utm_medium=readme&utm_campaign=llm-serving-observability), a DevOps, SRE and cloud consultancy in London. Running private models on GPUs and want them [monitored](https://www.oreonit.com/private-llm-hosting-and-operations/?utm_source=helm-chart&utm_medium=readme&utm_campaign=llm-serving-observability), sized and kept busy? That is the day job.
