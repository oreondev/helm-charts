# crawl4ai

[Crawl4AI](https://github.com/unclecode/crawl4ai) (web pages to clean Markdown and structured data for LLMs and RAG, over REST and MCP) on Kubernetes, tuned for running it in production rather than with the upstream Docker defaults.

What the chart changes compared with running the image as shipped (0.9.5, same flags: 4 GiB limit, read-only root, no capabilities; measured with `docker stats`, each run twice):

| | Image entrypoint | This chart |
|---|---|---|
| Start to ready | 6.0-6.9 s | 4.0 s |
| Memory after start | 399-483 MiB (supervisord + Redis + gunicorn) | 261 MiB, plus 4 MiB for the Redis sidecar |
| Memory after 5 crawls | 512-632 MiB | 320 MiB |
| Pod stop after a crawl | 12 s: the app hangs on shutdown and supervisord kills it after 10 s, with any in-flight crawl | 2.7 s, in-flight requests get `gunicorn.gracefulTimeout` |
| Reachable without a token | no: the entrypoint binds loopback, so the Service gets connection resets | token generated once (64 characters) and kept across upgrades |
| JWT signing key (`/token`) | random per process: tokens break on restart and on every other replica | generated once, shared by all replicas |
| Memory threshold for new browsers | 95% of the limit | 85%: Chromium allocates in bursts and the kernel kills at 100% |
| Rate limiting behind an Ingress | every client counts against the proxy's address | `gunicorn.forwardedAllowIps` makes it per client |
| Cloud advert in the logs on every start | yes | off |

- **gunicorn is PID 1**, configured from a rendered `gunicorn.conf.py` instead of supervisord. It handles SIGTERM and reaps the orphaned Chromium processes. The config file also bounds a shutdown wait in the egress proxy: its `stop()` waits for every client connection to close, Chromium keeps its tunnels open, so after the first crawl every shutdown hung until it was killed.
- **Redis as a native sidecar** (`redis.mode: sidecar`, the default): `redis-server` from the same image, so there is nothing extra to pull, loopback only, password from the chart Secret, in memory with `volatile-lru` so job results (which expire) can be evicted and nothing else. It starts before the API and stops after it.
- **Horizontal scaling with external Redis** (`redis.mode: external`): job state, results and rate-limit buckets move to your Redis, so a job submitted on one pod can be polled on another (tested). Then `replicaCount` or the HPA (CPU, slow scale-down so pods are not removed mid-crawl), a PodDisruptionBudget and spread across nodes. The chart refuses more than one replica with the sidecar.
- **Security flags stay off** and are one value each: deep crawling, Python hooks, `/execute_js`, crawling internal addresses (the egress guard refuses cluster Services and metadata endpoints unless `features.internalUrls`), the Chromium sandbox.
- **Upstream `config.yml` is shipped with the chart** and your `config` is deep-merged over it, so you override two keys instead of copying 150 lines.
- **Non-root (uid 999), read-only root filesystem**, sized emptyDirs for `/tmp`, `/dev/shm`, the crawl cache and the artifact store; the artifact quota follows `artifacts.size`.
- **Monitoring**: a ServiceMonitor that sends the API token (`/metrics` is behind the auth gate), alerts (API down, 5xx ratio, slow crawls, memory near the limit, OOM kills) and a Grafana dashboard. Changing only monitoring values does not restart the pod.

## Install

```bash
helm repo add oreonit https://oreondev.github.io/helm-charts
helm install crawl4ai oreonit/crawl4ai -n crawl4ai --create-namespace -f crawl4ai.yaml
kubectl -n crawl4ai get secret crawl4ai -o jsonpath='{.data.CRAWL4AI_API_TOKEN}' | base64 -d
```

`crawl4ai.yaml` for a production setup on GKE with Memorystore:

```yaml
redis:
  mode: external
  external:
    host: 10.20.0.3              # Memorystore for Redis
    existingSecret: crawl4ai-redis
autoscaling:
  enabled: true
  minReplicas: 2
  maxReplicas: 8

llm:
  provider: openai/gpt-4o-mini   # or anthropic/..., gemini/..., a vLLM endpoint with llm.baseUrl
secretEnv:
  OPENAI_API_KEY: ...

config:
  limits:
    wall_clock_s: 120
  crawler:
    pool:
      max_pages: 20              # pages open at once per pod; about 100-150 MiB each

gunicorn:
  forwardedAllowIps: "*"         # only the load balancer reaches the pods

ingress:
  enabled: true
  className: nginx
  annotations:
    nginx.ingress.kubernetes.io/proxy-read-timeout: "1800"
  hosts:
    - host: crawl.example.com
      paths: [{ path: /, pathType: Prefix }]
  tls:
    - secretName: crawl-tls
      hosts: [crawl.example.com]

metrics:
  serviceMonitor: { enabled: true }
  prometheusRule: { enabled: true }
  dashboard: { enabled: true }
```

Then:

```bash
curl -s https://crawl.example.com/md -H "Authorization: Bearer $TOKEN" \
  -H 'content-type: application/json' -d '{"url":"https://example.com"}'
```

MCP clients connect to `/mcp/sse` (or `/mcp/ws`) with the same bearer token.

### Sizing and cold starts

The image is 2.3 GB to download and 5.7 GB unpacked (Chromium, Playwright, Python). On a warm node the pod is ready in about 4 seconds; on a new node the pull dominates. On GKE enable [image streaming](https://cloud.google.com/kubernetes-engine/docs/how-to/image-streaming) or keep a minimum of nodes with the image cached, and mirror the image into your own registry.

Memory follows open pages: `crawler.pool.max_pages` (40 upstream) times 100-150 MiB, plus about 300 MiB for the process. Keep `resources.limits.memory` above that, or lower `max_pages`; the memory alert and the dashboard show how close a pod gets.

### Artifacts with more than one replica

Screenshots and PDFs are stored on the pod that made them and fetched later from `/artifacts/<id>`. With several replicas that request can land on another pod; return them inline in the response, or mount a ReadWriteMany volume with `artifacts.existingClaim`.

## Values

| Key | Default | |
|---|---|---|
| `image.tag` / `image.digest` | appVersion | pin one in production |
| `auth.apiToken` / `auth.existingSecret` | generated | `CRAWL4AI_API_TOKEN` |
| `redis.mode` | `sidecar` | or `external` (needed for more than one replica) |
| `redis.external.host` / `.port` / `.db` / `.tls` / `.existingSecret` | | your Redis |
| `redis.taskTtlSeconds` | `3600` | how long job results are kept |
| `features.deepCrawl` / `.hooks` / `.executeJs` / `.internalUrls` / `.chromiumSandbox` | `false` | upstream security flags |
| `llm.provider` / `llm.baseUrl` | | default LLM for extraction and `/llm` |
| `config` | memory threshold 85% | deep-merged over the upstream `config.yml` |
| `gunicorn.threads` / `.timeout` / `.gracefulTimeout` / `.forwardedAllowIps` | 4 / 1800 / 30 / | one worker per pod by design |
| `env` / `secretEnv` / `extraEnv` / `extraEnvFrom` | | more variables, e.g. `OPENAI_API_KEY` in `secretEnv` |
| `replicaCount`, `autoscaling.*` | 1, off | need `redis.mode: external` |
| `resources` | 500m / 1Gi, limit 4Gi | |
| `artifacts.size` / `.ttlSeconds` / `.existingClaim` | 1Gi / 3600 / | screenshots and PDFs |
| `shm.sizeLimit`, `tmp.sizeLimit`, `cache.sizeLimit` | 1Gi, 2Gi, 1Gi | |
| `ingress.*`, `httpRoute.*` | off | long timeouts for crawls and streams |
| `metrics.serviceMonitor`, `.prometheusRule`, `.dashboard` | off | with thresholds `errorRatio`, `slowRequestSeconds`, `memoryRatio` |

Everything is validated by `values.schema.json`.

## Credits and licence

This product includes software developed by UncleCode (https://x.com/unclecode) as part of the Crawl4AI project (https://github.com/unclecode/crawl4ai). The chart deploys the upstream image unmodified.

The chart is MIT licensed and maintained by [Oreon IT](https://www.oreonit.com/?utm_source=helm-chart&utm_medium=readme&utm_campaign=crawl4ai), a DevOps, SRE and cloud consultancy in London. If you run crawling or other AI workloads on Kubernetes and want them sized, monitored and kept up to date, [that is the day job](https://www.oreonit.com/containerization-orchestration-management-kubernetes-openshift/?utm_source=helm-chart&utm_medium=readme&utm_campaign=crawl4ai).
