# mem0

[Mem0](https://github.com/mem0ai/mem0) (the memory layer for AI agents: facts extracted from conversations, stored as embeddings in PostgreSQL with pgvector, searched per user, agent or run) on Kubernetes: the self-hosted API server and its dashboard, set up for production. Bring your own PostgreSQL with pgvector (Cloud SQL, AlloyDB, RDS, Azure Database for PostgreSQL, CloudNativePG).

Upstream publishes no maintained images (the last `mem0/mem0-api-server` push is from September 2025, before auth and the dashboard), and its Dockerfiles are written for Docker Compose. The chart uses [images built from the upstream release](../../images/mem0) and does the setup the compose file leaves to you:

| | Upstream image and compose file | This chart |
|---|---|---|
| Image | build it yourself; `mem0ai>=0.1.48` resolves to whatever is newest that day | `ghcr.io/oreondev/mem0-server` / `mem0-dashboard`, pinned to the release, amd64 and arm64 |
| Starts on its own | no: without the compose volume `/app/history` is missing and the server fails, while `uvicorn --reload` keeps the container "Up" | yes; history on a PVC (or an emptyDir) |
| Server process | file-watching reloader + worker: 3 processes, 233 MiB | one process, 210 MiB |
| Databases and pgvector | `init-db.sh` in the Postgres container (only on a fresh volume) | init container: creates both databases if missing, `CREATE EXTENSION vector`, waits for PostgreSQL |
| Migrations | only in the dev compose command | `alembic upgrade head` in an init container on every rollout |
| First admin | the first visitor to the dashboard's `/setup` page becomes admin | `auth.admin.email`: created before the server starts, password generated into the Secret |
| `JWT_SECRET`, `ADMIN_API_KEY` | set them by hand | generated once, kept across upgrades |
| Health checks | none; `GET /` writes a request-log row each time | `/healthz`, `/readyz` (checks the app database), not logged |
| Request log | grows by about 864k rows a day at 10 req/s until you add a cron job | pruned daily by a CronJob (`requestLogPruning.retentionDays`, 30) |
| Telemetry to PostHog | on | off (`telemetry`) |
| User / filesystem | root, writable | uid 10001, read-only root filesystem, no capabilities |
| Metrics | none | every route on port 9090 (never on the API port), ServiceMonitor, alerts, Grafana dashboard |

## Install

```bash
helm repo add oreonit https://oreondev.github.io/helm-charts
helm install mem0 oreonit/mem0 -n mem0 --create-namespace -f mem0.yaml
kubectl -n mem0 get secret mem0 -o jsonpath='{.data.ADMIN_API_KEY}' | base64 -d
```

`mem0.yaml` on GKE with Cloud SQL for PostgreSQL (pgvector is available there; the user needs `cloudsqlsuperuser` for `CREATE EXTENSION`, or create the extension once yourself and set `createDatabases: false`):

```yaml
database:
  host: 10.30.0.5
  user: mem0
  existingSecret: mem0-db            # key POSTGRES_PASSWORD
  sslMode: require

auth:
  admin:
    email: platform@example.com      # password: kubectl get secret mem0 ... ADMIN_PASSWORD

secretEnv:
  OPENAI_API_KEY: sk-...

ingress:
  enabled: true
  className: nginx
  api:
    host: mem0-api.example.com
  dashboard:
    host: mem0.example.com
  tls:
    - secretName: mem0-tls
      hosts: [mem0-api.example.com, mem0.example.com]

metrics:
  serviceMonitor: { enabled: true }
  prometheusRule: { enabled: true }
  dashboard: { enabled: true }
```

Agents then use the API with `X-API-Key` (the admin key, or per-user keys created in the dashboard):

```bash
curl -s https://mem0-api.example.com/memories -H "X-API-Key: $KEY" -H 'content-type: application/json' \
  -d '{"messages":[{"role":"user","content":"I prefer tea over coffee"}],"user_id":"alice"}'
curl -s https://mem0-api.example.com/search -H "X-API-Key: $KEY" -H 'content-type: application/json' \
  -d '{"query":"drinks","filters":{"user_id":"alice"}}'
```

The dashboard runs in the browser and calls the API directly, which is why both get a public host (`apiUrl` and `dashboardUrl` override them). CORS on the API allows the dashboard's URL only.

### Private models

`llm.openaiBaseUrl` points the bundled OpenAI provider at any OpenAI-compatible endpoint: vLLM, Ollama, LiteLLM or a gateway in front of Azure OpenAI or Bedrock, for example a Service in the same cluster (`http://vllm.models:8000/v1`). It has to serve both chat completions and embeddings; set `llm.model` and `llm.embedderModel` to what it serves. The collection is created with 1536 dimensions (OpenAI `text-embedding-3-small`) the first time the server starts; for an embedder with other dimensions, set `vector_store.config.embedding_model_dims` and `embedder.config.embedding_dims` with `POST /configure` (or in the dashboard) and use a new `database.collection` before storing memories. Anthropic and Gemini can be selected at runtime in the dashboard (Configuration), which stores the override in the app database.

### Replicas

The server keeps two things per process: the memory change history (`GET /memories/{id}/history`, a SQLite file) and runtime configuration changes made in the dashboard (applied to the pod that received them until the others restart). The chart therefore runs one replica with the history on a ReadWriteOnce volume and the Recreate strategy. For more replicas set `server.persistence.enabled: false` and `server.replicaCount`; memories and search are shared through PostgreSQL, the history is then per pod, and configuration belongs in values rather than the dashboard.

## Values

| Key | Default | |
|---|---|---|
| `image.server` / `image.dashboard` | `ghcr.io/oreondev/mem0-*`, appVersion | `tag` or `digest` to pin |
| `database.host` / `.port` / `.user` / `.password` / `.existingSecret` | | PostgreSQL with pgvector |
| `database.name` / `.appName` / `.collection` | `mem0` / `mem0_app` / `memories` | memories, app data, table |
| `database.sslMode` | `prefer` | libpq `sslmode` |
| `database.createDatabases` / `.migrations` | `true` / `true` | init containers |
| `auth.jwtSecret` / `.adminApiKey` / `.existingSecret` | generated | |
| `auth.admin.email` / `.name` / `.password` | | first dashboard admin; password generated |
| `llm.model` / `.embedderModel` / `.openaiBaseUrl` | `gpt-5-mini` / `text-embedding-3-small` / | |
| `secretEnv` / `env` / `extraEnv` / `extraEnvFrom` | | `OPENAI_API_KEY` and other variables |
| `server.replicaCount` / `.persistence.*` / `.resources` | 1 / 1Gi PVC / 100m, 256Mi, limit 1Gi | |
| `server.forwardedAllowIps` | | trust the proxy's `X-Forwarded-For` (login rate limit) |
| `dashboard.enabled` / `.instanceName` / `.resources` | `true` / `Mem0` | |
| `apiUrl` / `dashboardUrl` | first ingress/HTTPRoute host | public URLs |
| `ingress.*`, `httpRoute.*` | off | one host for the API, one for the dashboard |
| `requestLogPruning.enabled` / `.schedule` / `.retentionDays` | on / 03:17 daily / 30 | |
| `telemetry` | `false` | |
| `metrics.enabled`, `.serviceMonitor`, `.prometheusRule`, `.dashboard` | on, off, off, off | |

Everything is validated by `values.schema.json`.

## Backups

Everything that matters is in PostgreSQL (memories and embeddings in `database.name`, users, keys and settings in `database.appName`), so back up the database the way you back up PostgreSQL: Cloud SQL backups and point-in-time recovery, or CloudNativePG's barman backups. The history volume can be covered with [velero-backup-schedules](../velero-backup-schedules).

## Credits and licence

Mem0 is developed by [Mem0](https://github.com/mem0ai/mem0) under the Apache-2.0 licence; the images are built from its release source without changes to the upstream code.

The chart is MIT licensed and maintained by [Oreon IT](https://www.oreonit.com/?utm_source=helm-chart&utm_medium=readme&utm_campaign=mem0), a DevOps, SRE and cloud consultancy in London. If you run agents and their memory, vector databases or private models on Kubernetes and want them operated properly, [that is the day job](https://www.oreonit.com/containerization-orchestration-management-kubernetes-openshift/?utm_source=helm-chart&utm_medium=readme&utm_campaign=mem0).
