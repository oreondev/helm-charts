# evolution

[Evolution API](https://github.com/evolution-foundation/evolution-api) (WhatsApp through Baileys or the official Cloud API, with the manager UI) on Kubernetes, tuned for running it in production rather than with the upstream Docker Compose defaults. Bring your own PostgreSQL (or MySQL) and Redis.

What the chart changes compared with running the image as shipped (measured on 2.3.7, same database, restart with no pending migrations):

| | Image entrypoint | This chart |
|---|---|---|
| Start to ready | 16.1 s | 5.9 s |
| Memory after start | 329 MiB (bash + npm + node) | 221 MiB |
| Pod stop | 31.6 s (SIGTERM ignored, killed at the grace period) | 2.5 s |
| Database URL with password in the log | on every start | never |
| Health probes | `GET /` calls web.whatsapp.com each time | static `/manager/` page, no outbound call |
| Settings not set explicitly | taken from the example `.env` baked into the image (example API key, telemetry on, verbose logs) | masked; only chart and your values apply |
| Time zone | America/Sao_Paulo (image default) | UTC (`defaults.TZ`) |
| User / filesystem | root, writable | uid 1000, read-only root filesystem, no capabilities |

- **Migrations** run once per rollout in a `migrate` init container (`prisma migrate deploy`). The API container starts `node dist/main` directly, with a small shell that forwards SIGTERM (Node registers no signal handlers and the kernel ignores SIGTERM for PID 1). The image's Prisma client is generated for PostgreSQL; with `database.provider: mysql` an init container regenerates it into a shared volume.
- **One replica, Recreate.** WhatsApp sessions are live sockets inside the process. Two pods would connect the same numbers and log each other out, so there is no `replicaCount` and no HPA. Scale with resources, or run one release per tenant group with different `database.clientName`.
- **Heap cap** `NODE_OPTIONS=--max-old-space-size` at 75% of `resources.limits.memory`, so V8 collects garbage before the kernel kills the pod.
- **Sessions without a volume.** With Redis enabled the Baileys signal keys live in Redis and the credentials in the database, so the pod needs no PVC. Without Redis the keys are files and the chart refuses to render unless `persistence.enabled: true`.
- **Message history off by default** (`database.save.historic: false`). On every new connection WhatsApp pushes months of chats; storing them costs CPU, database rows and minutes before the instance is usable. Turn it on if you need history.
- **API key** generated once (32 characters) and kept across upgrades, or taken from your Secret. Metrics password the same.
- **Access**: Ingress or a Gateway API HTTPRoute (for example onto the Gateway from [gateway-api-baseline](../gateway-api-baseline)), `SERVER_URL` derived from the first host.
- **Monitoring** (optional): `/metrics` with basic auth, a ServiceMonitor that renames the API's `instance` label to `wa_instance` (it clashes with Prometheus' target label), and alerts: API down, WhatsApp instance disconnected for 15 minutes (with its state), no instances loaded after a restart.

## Install

```bash
helm repo add oreonit https://oreondev.github.io/helm-charts
helm install evolution oreonit/evolution -n whatsapp --create-namespace -f evolution.yaml
kubectl -n whatsapp get secret evolution -o jsonpath='{.data.AUTHENTICATION_API_KEY}' | base64 -d
```

`evolution.yaml`:

```yaml
database:
  existingSecret: evolution-db          # key DATABASE_CONNECTION_URI:
                                        # postgresql://evolution:...@postgres:5432/evolution?schema=evolution_api
redis:
  uri: redis://redis-master:6379/6      # persistent (AOF), maxmemory-policy noeviction

ingress:
  enabled: true
  className: nginx
  annotations:
    nginx.ingress.kubernetes.io/proxy-body-size: 136m
    nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"
  hosts:
    - host: whatsapp.example.com
      paths: [{ path: /, pathType: Prefix }]
  tls:
    - secretName: whatsapp-tls
      hosts: [whatsapp.example.com]

config:                                 # any Evolution API variable
  WEBHOOK_GLOBAL_ENABLED: "true"
  WEBHOOK_GLOBAL_URL: https://n8n.example.com/webhook/whatsapp
  WEBHOOK_EVENTS_MESSAGES_UPSERT: "true"
  S3_ENABLED: "true"
  S3_BUCKET: whatsapp-media
  S3_ENDPOINT: storage.googleapis.com
secretEnv:
  S3_ACCESS_KEY: ...
  S3_SECRET_KEY: ...

metrics:
  enabled: true
  serviceMonitor: { enabled: true }
  prometheusRule: { enabled: true }
```

Redis matters more than it looks: the signal keys of every paired phone are in it. If Redis loses them (no persistence, or an eviction policy that drops keys) the phones are logged out and need a new QR scan.

PgBouncer: point `database.uri` at PgBouncer with `pgbouncer=true` and set `database.migrations.uri` to the direct server (migrations need a session connection).

## Values

| Key | Default | |
|---|---|---|
| `image.tag` / `image.digest` | `v` + appVersion | pin one in production |
| `serverUrl` | first ingress/HTTPRoute host | `SERVER_URL` |
| `auth.apiKey` / `auth.existingSecret` | generated | global API key |
| `database.provider` | `postgresql` | or `mysql` |
| `database.uri` / `database.existingSecret` | | `DATABASE_CONNECTION_URI`, templated |
| `database.migrations.enabled` / `.uri` | `true` / uri | init container, direct URL for PgBouncer setups |
| `database.save.*` | all on except `historic` | what is stored |
| `redis.enabled` / `redis.uri` / `redis.existingSecret` | `true` | `CACHE_REDIS_URI` |
| `metrics.enabled`, `.serviceMonitor.enabled`, `.prometheusRule.enabled` | `false` | |
| `config` | `{}` | any variable, overrides `defaults` |
| `secretEnv` | `{}` | secret variables, into the chart's Secret |
| `extraEnvFrom` | `[]` | your ConfigMaps/Secrets, loaded last so they win |
| `maskImageDotenv` | `true` | hide the image's example `.env` |
| `resources` | 100m / 384Mi, limit 1Gi | |
| `nodeMaxOldSpaceMB` | 75% of the memory limit | |
| `persistence.enabled` / `.store.enabled` | `false` | signal keys without Redis / media without S3 |
| `ingress.*`, `httpRoute.*` | off | |
| `manager.enabled` | `true` | the `/manager` UI; probes fall back to TCP when off |

Everything is validated by `values.schema.json`.

## Upgrading from 0.1.0

0.1.0 was a generic scaffold. The selector labels are unchanged, so `helm upgrade` works in place, but:

- `replicaCount`, `autoscaling`, `existingConfigMap`, `configMountPath`, `configFileName`, `extraArgs`, `serviceAccountName` are gone (the schema rejects them). Evolution API reads environment variables only; put them in `config`, `secretEnv` or keep your own ConfigMap/Secret in `extraEnvFrom`.
- `config` is now a map of environment variables, not a rendered `config.yaml`.
- The Service is named after the release (`<release>-evolution`) and listens on 8080. Set `service.name: evolution` and `service.port: 80` to keep the old name and port.
- `extraEnvFrom` is no longer pre-filled with `evolution-cm` / `evolution-secret`; add them back if you use them. Keys there override the chart's.
- The image moved from `atendai/evolution-api`, which can no longer be pulled from Docker Hub, to the official `evoapicloud/evolution-api`.

## Licence

MIT. Maintained by [Oreon IT](https://www.oreonit.com/), a DevOps, SRE and cloud consultancy in London. If you want WhatsApp automation run on a [production Kubernetes platform](https://www.oreonit.com/containerization-orchestration-management-kubernetes-openshift/) with [observability](https://www.oreonit.com/observability-and-monitoring-consultancy-services/) built in, that is the day job.
