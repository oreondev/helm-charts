# text-embeddings-inference

[Hugging Face Text Embeddings Inference](https://github.com/huggingface/text-embeddings-inference) (TEI: a fast server for embedding, reranker and classifier models) on Kubernetes, on CPU or NVIDIA GPUs. One release serves several models, each with its own Deployment (or StatefulSet) and Service, so RAG pipelines and agent memory (Mem0, LangChain, LlamaIndex, LiteLLM, Open WebUI) embed and rerank on your own infrastructure instead of a paid API.

What the chart does compared with running the image as documented (`docker run -p 8080:80 -v $volume:/data ... --model-id ...`), measured on 1.9.4:

| | Image as documented | This chart |
|---|---|---|
| Models | one per container | a list: `models: [{name, modelId, accelerator, ...}]`, a Service each |
| Image variant | pick the tag by GPU generation yourself (`cpu-`, `turing-`, `86-`, `89-`, `hopper-`, `100-`, `120-` ...) | from `accelerator: cpu | ada | hopper | ...`; GPU variants request `nvidia.com/gpu`, tolerate GPU taints and use Recreate |
| Model files | downloaded into the container on start unless you mount a volume | `cache.mode`: `persistent` (a PVC per replica via a StatefulSet) or a shared ReadWriteMany claim. Restarting bge-small on CPU: 30-31 s on an empty cache, 7-9 s with the kept cache (download plus TEI's optimised model files); large models save minutes |
| Authentication | none unless you pass `--api-key` | API key generated and kept, `Authorization: Bearer`; `/health` stays open for probes |
| User / filesystem | root, port 80 | uid 1000 on port 8080, read-only root filesystem, no capabilities |
| Threads | `RAYON_NUM_THREADS=8` whatever the CPU | sized to the pod's CPU limit or request |
| Probes | none | startup probe with a budget for the download, liveness and readiness on `/health` |
| Scaling | none | CPU HPA, or KEDA on TEI's own queue length (`te_queue_size`), which also works for GPU models |
| Monitoring | `/metrics` | ServiceMonitor with a `model` label, alerts (model down, p95 latency, queue backlog, failure ratio, memory near the limit), Grafana dashboard |

Tested on a kind cluster with `BAAI/bge-small-en-v1.5` and `cross-encoder/ms-marco-MiniLM-L-6-v2`: OpenAI-compatible `/v1/embeddings`, `/rerank`, 401 without the key, every alert and dashboard query evaluating against Prometheus.

## Install

```bash
helm repo add oreonit https://oreondev.github.io/helm-charts
helm install embeddings oreonit/text-embeddings-inference -n ai --create-namespace -f embeddings.yaml
kubectl -n ai get secret embeddings-tei -o jsonpath='{.data.api-key}' | base64 -d
```

`embeddings.yaml` with a multilingual embedding model and a reranker on an L4 GPU node pool (GKE), and a small CPU model:

```yaml
models:
  - name: bge-m3
    modelId: BAAI/bge-m3
    accelerator: ada                    # 89-<version> image, one nvidia.com/gpu
    cache: { mode: persistent, size: 20Gi }
    resources:
      requests: { cpu: "2", memory: 8Gi }
      limits: { memory: 16Gi }
    nodeSelector:
      cloud.google.com/gke-accelerator: nvidia-l4
    autoscaling:
      keda: { enabled: true }           # 1-4 replicas, one per 64 queued requests
  - name: reranker
    modelId: BAAI/bge-reranker-v2-m3
    accelerator: ada
    cache: { mode: persistent, size: 10Gi }
    nodeSelector:
      cloud.google.com/gke-accelerator: nvidia-l4
  - name: minilm
    modelId: sentence-transformers/all-MiniLM-L6-v2
    resources:
      requests: { cpu: "1", memory: 1Gi }
      limits: { cpu: "2", memory: 2Gi }

metrics:
  serviceMonitor: { enabled: true }
  prometheusRule: { enabled: true }
  dashboard: { enabled: true }
```

### Using it

Every model answers the OpenAI embeddings API, so most clients only need a base URL and the key:

```python
from openai import OpenAI
client = OpenAI(base_url="http://embeddings-tei-bge-m3.ai.svc:8080/v1", api_key=KEY)
client.embeddings.create(model="bge-m3", input=["Kubernetes autoscaling", "Prometheus alerting"])
```

- **[Mem0](../mem0):** `llm.openaiBaseUrl` pointing at the model's `/v1`. Set the collection's embedding dimensions to the model's: 1024 for bge-m3, 384 for MiniLM.
- **LiteLLM:** a model with `api_base: http://...:8080/v1`.
- **Rerankers:** answer `POST /rerank` with `{"query": ..., "texts": [...]}`.
- **Classifiers:** answer `POST /predict`.

The API docs are at `/docs`.

### Choosing hardware

- **CPU:** small models (MiniLM, bge-small, e5-small) run well on CPU for moderate traffic. Throughput scales with cores; on 2 CPUs, bge-small embedded about 80 texts per second in batches of 32.
- **GPU:** large models (bge-m3, gte-large, Qwen3-Embedding) and rerankers under load belong on a GPU; set `accelerator` to the GPU generation.
- **Batching:** `maxBatchTokens` and `maxConcurrentRequests` trade latency for throughput. The dashboard's queue versus inference panel shows which one is the bottleneck.

## Values

| Key | Default | |
|---|---|---|
| `models[]` | `bge-small` | `name`, `modelId` plus any `modelDefaults` key |
| `modelDefaults.accelerator` | `cpu` | `cpu`, `cpu-arm64`, `turing`, `ampere`, `ampere-86`, `ada`, `hopper`, `blackwell`, `blackwell-120` |
| `modelDefaults.revision` / `.dtype` / `.pooling` | | TEI options |
| `modelDefaults.maxConcurrentRequests` / `.maxBatchTokens` / `.maxClientBatchSize` / `.autoTruncate` / `.payloadLimit` | 512 / 16384 / 32 / true / 2 MB | |
| `modelDefaults.replicaCount` / `.resources` | 1 / 1 CPU, 1Gi, limit 2Gi | |
| `modelDefaults.cache.mode` / `.size` / `.storageClass` / `.existingClaim` | `emptyDir` / 10Gi | `persistent` makes the workload a StatefulSet |
| `modelDefaults.autoscaling.*` | off | CPU HPA or `keda` |
| `modelDefaults.nodeSelector` / `.tolerations` / `.runtimeClassName` / `.extraArgs` / `.env` | | |
| `auth.enabled` / `.apiKey` / `.existingSecret` | on / generated | |
| `huggingface.token` / `.existingSecret` | | gated and private models |
| `networkPolicy.*` | off | callers allow list, plus the monitoring namespace |
| `metrics.enabled`, `.serviceMonitor`, `.prometheusRule`, `.dashboard` | on, off, off, off | |

Everything is validated by `values.schema.json`, including each entry in `models`.

## Credits and licence

Text Embeddings Inference is developed by [Hugging Face](https://github.com/huggingface/text-embeddings-inference) under the Apache-2.0 licence. The chart deploys the upstream images unmodified; models keep their own licences.

The chart is MIT licensed and maintained by [Oreon IT](https://www.oreonit.com/?utm_source=helm-chart&utm_medium=readme&utm_campaign=text-embeddings-inference), a DevOps, SRE and cloud consultancy in London. If you want embeddings, rerankers and private models run on your own Kubernetes with GPUs sized, scaled and monitored, [that is the day job](https://www.oreonit.com/private-llm-hosting-and-operations/?utm_source=helm-chart&utm_medium=readme&utm_campaign=text-embeddings-inference).
