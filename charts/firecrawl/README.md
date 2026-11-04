# firecrawl

[Firecrawl](https://github.com/firecrawl/firecrawl) (turns websites into clean Markdown and structured data for LLMs: scrape, crawl, map, search, extract) on Kubernetes, built for running it in production rather than as the upstream all-in-one container.

Upstream's self-hosted container starts the API and every worker as child processes of one harness, and its own Kubernetes example chart says it is a starting point, not a production setup. What this chart does differently (measured on 2.11.621 against the upstream Docker Compose stack and the upstream Kubernetes manifests):

| | Upstream | This chart |
|---|---|---|
| Authentication | none: with `USE_DB_AUTHENTICATION=false` every request is served, with any key or none | token gate in the API pods: only `Authorization: Bearer <key>` with a configured key, else 401 (keys generated, kept across upgrades) |
| Process layout | API, crawl worker, extract worker, 5 scrape workers, prefetch and reconciler in one 2.49 GiB container, scaled as a whole | one Deployment per component, each with its own requests, probes, heap cap and scaling |
| Scaling scrape workers | fixed count per container | CPU HPA, or KEDA on the queue itself (`nuq_queue_scrape_job_count{status="queued"}`) |
| API pod shutdown on Kubernetes | sleeps 60 s "for GCE load balancer drain" on every SIGTERM (`IS_KUBERNETES`) | 10 s preStop drain (`api.drainSeconds`), then closes in about 0.1 s |
| Playwright service | `pnpm start` (pnpm plus node), 248 MiB; the service only handles SIGINT | node directly, 140 MiB; SIGTERM is passed on as SIGINT so it closes its browser cleanly |
| Queue schema on managed PostgreSQL | `nuq.sql` runs `ALTER SYSTEM`, which Cloud SQL and RDS refuse (`permission denied to set parameter`) | applied by a Job on every release, `ALTER SYSTEM` skipped for external databases, pg_cron checked first with a clear message (tested as a non-superuser: all 36 pg_cron jobs created) |
| Queue database WAL | `min_wal_size 4GB`, `max_wal_size 16GB` via `ALTER SYSTEM`, sized for upstream's cloud disks | 256 MB / 4 GB on the bundled StatefulSet (`postgres.bundled.walSize`), so a 20 GiB volume does not fill with WAL |
| Images | the Playwright and queue database images are published only as `latest` | pinned to the multi-arch digests current with the release |
| RabbitMQ and FoundationDB | both started by the compose file (184 MiB), RabbitMQ required by the queue settings | not needed: the queue waits on PostgreSQL LISTEN/NOTIFY; RabbitMQ only when the extract worker is on |
| Security | API and workers as root, writable, every port reachable | non-root, read-only root filesystem, no capabilities; NetworkPolicy: gate open, API port only within the release, admin listener only from the monitoring namespace (tested) |
| Monitoring | metrics on internal ports, nothing scrapes them | PodMonitor (worker metrics and queue depth), alerts (backlog, stalled queue, job failure ratio, component down), Grafana dashboard |

## Install

```bash
helm repo add oreonit https://oreondev.github.io/helm-charts
helm install firecrawl oreonit/firecrawl -n firecrawl --create-namespace -f firecrawl.yaml
kubectl -n firecrawl get secret firecrawl-gateway-keys -o jsonpath='{.data.api-keys}' | base64 -d
```

Everything is bundled by default (PostgreSQL with pg_cron, Redis), so an empty `firecrawl.yaml` works. A production setup on GKE with Cloud SQL and Memorystore:

```yaml
postgres:
  mode: external
  user: firecrawl
  database: firecrawl
  existingSecret: firecrawl-db          # key "password"
  external:
    host: 10.40.0.3                     # Cloud SQL with cloudsql.enable_pg_cron=on, cron.database_name=firecrawl
redis:
  mode: external
  external:
    url: redis://10.40.0.12:6379

nuqWorker:
  autoscaling:
    keda:
      enabled: true                     # 2-10 workers, one per 20 queued jobs
playwright:
  autoscaling:
    enabled: true

ingress:
  enabled: true
  className: nginx
  annotations:
    nginx.ingress.kubernetes.io/proxy-read-timeout: "300"
  hosts:
    - host: firecrawl.example.com
      paths: [{ path: /, pathType: Prefix }]
  tls:
    - secretName: firecrawl-tls
      hosts: [firecrawl.example.com]

metrics:
  podMonitor: { enabled: true }
  prometheusRule: { enabled: true }
  dashboard: { enabled: true }
```

Then point any Firecrawl SDK at it:

```python
from firecrawl import Firecrawl
app = Firecrawl(api_key="fc-...", api_url="https://firecrawl.example.com")
print(app.scrape("https://example.com", formats=["markdown"]).markdown)
```

### Components

| Component | Runs | Scale with |
|---|---|---|
| `api` + `gateway` | HTTP API and the token gate | `api.replicaCount`, `api.autoscaling` |
| `worker` | crawl orchestration | `worker.replicaCount` |
| `nuq-worker` | scrape jobs from the queue | `nuqWorker.replicaCount`, `.autoscaling` (CPU) or `.autoscaling.keda` (queue depth) |
| `nuq-prefetch-worker`, `nuq-reconciler-worker` | backlog and concurrency housekeeping | one each, by design |
| `playwright` | headless Chromium for JavaScript pages | `playwright.replicaCount`, `.autoscaling`, `.maxConcurrentPages` |
| `extract-worker` | `/extract` with an LLM | off by default; needs `rabbitmq.mode` and an LLM key in `secretEnv` |
| `postgres`, `redis`, `rabbitmq` | bundled state | or `mode: external` |

A scrape job's throughput is set by `nuqWorker` replicas times `firecrawl.numWorkersPerQueue` (8), and JavaScript pages by `playwright` replicas times `maxConcurrentPages` (10).

### PostgreSQL requirements (external)

The queue's cleanup, lock reaper and nightly reindexing run in pg_cron, so the database needs `pg_cron` in `shared_preload_libraries` and `cron.database_name` set to `postgres.database`: Cloud SQL flag `cloudsql.enable_pg_cron`, an RDS or Aurora parameter group, or an AlloyDB flag. The schema Job checks this before touching anything. Use a direct connection, not PgBouncer in transaction mode: the workers rely on LISTEN/NOTIFY.

### Private models

`/extract` and the JSON format use an LLM. With `secretEnv.OPENAI_API_KEY` they use OpenAI; for a private model set `firecrawl.env.OPENAI_BASE_URL` to an OpenAI-compatible endpoint (vLLM, LiteLLM) and `MODEL_NAME`, or `OLLAMA_BASE_URL`.

## Values

| Key | Default | |
|---|---|---|
| `image.tag` / `image.digest` | appVersion | the plain release tag (upstream also pushes `-staging` builds) |
| `auth.enabled` / `.apiKeys` / `.existingSecret` | on / generated / | token gate |
| `firecrawl.numWorkersPerQueue` / `.crawlConcurrentRequests` / `.maxConcurrentJobs` | 8 / 10 / 5 | |
| `firecrawl.waitMode` | `listen` | PostgreSQL LISTEN/NOTIFY instead of polling |
| `firecrawl.trustProxyHops` | 2 with the gate | `EXPRESS_TRUST_PROXY`, for https URLs in responses |
| `firecrawl.env` / `secretEnv` / `extraEnv` / `extraEnvFrom` | | more variables (proxy, SearXNG, LLM) |
| `api.*`, `worker.*`, `nuqWorker.*`, `nuqPrefetchWorker.*`, `nuqReconcilerWorker.*`, `extractWorker.*`, `playwright.*` | see values.yaml | replicas, resources (heap cap at 75% of the limit), autoscaling |
| `postgres.mode` / `redis.mode` / `rabbitmq.mode` | bundled / bundled / none | |
| `postgres.bundled.persistence.size` / `.walSize` / `.sharedBuffers` | 20Gi / 256MB-4GB / 256MB | |
| `postgres.schema.enabled` | on | queue schema Job per release |
| `ingress.*`, `httpRoute.*` | off | |
| `networkPolicy.enabled` / `.metricsNamespaceSelector` | on / `monitoring` | |
| `metrics.enabled`, `.podMonitor`, `.prometheusRule`, `.dashboard` | on, off, off, off | |

Everything is validated by `values.schema.json`.

## Credits and licence

Firecrawl is developed by the [Firecrawl team](https://github.com/firecrawl/firecrawl) under the AGPL-3.0. The chart deploys the upstream images unmodified; `files/nuq.sql` is the upstream queue schema from the release, unmodified and under its AGPL-3.0 licence.

The chart itself is MIT licensed and maintained by [Oreon IT](https://www.oreonit.com/?utm_source=helm-chart&utm_medium=readme&utm_campaign=firecrawl), a DevOps, SRE and cloud consultancy in London. If you run crawling, RAG pipelines or other AI workloads on Kubernetes and want them scaled, monitored and kept up to date, [that is the day job](https://www.oreonit.com/containerization-orchestration-management-kubernetes-openshift/?utm_source=helm-chart&utm_medium=readme&utm_campaign=firecrawl).
