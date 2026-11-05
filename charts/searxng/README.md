# searxng

[SearXNG](https://github.com/searxng/searxng) (metasearch: queries several search engines and merges the results, without tracking) on Kubernetes. Two modes:

- **api** (default): the search backend for programs. Firecrawl's `/search`, Open WebUI web search, Perplexica, LangChain and LlamaIndex tools and your own agents call `/search?format=json`. JSON on, rate limiter off, kept inside the cluster (optionally behind a NetworkPolicy).
- **public**: an instance people use in a browser. Rate limiter and bot detection with Valkey, public-instance features, served through an Ingress or Gateway.

What the chart changes compared with running the image as shipped (2026.10.29, measured on a kind cluster):

| | Image as shipped | This chart |
|---|---|---|
| `/search?format=json` | 403: only `html` is enabled | on in api mode (`html`, `json`, `csv`, `rss`) |
| Secret key | random, written on a container's first start: each replica and each restart without a volume has its own, so image-proxy links and preference cookies break across pods | generated once, shared by all replicas, kept across upgrades |
| Engines | 121 enabled, including torrent, piratebay and onion engines (two of which fail to load without Tor) | `curated` profile: 20 web, IT and science engines; same results on general queries, 15-25% less memory; `default` keeps upstream's set |
| User / filesystem | root, writable config volume | uid 977, read-only root filesystem, config from a Secret |
| Start | entrypoint copies a template and warns about volume ownership on every start | Granian started directly |
| Rate limiter (public) | needs a separately run Valkey and a `limiter.toml` | Valkey as a native sidecar (or external), trusted proxies for your ingress from values; tested: scripted clients get 429, browsers 200 |
| Metrics | off | `/metrics` with basic auth, ServiceMonitor, alerts (down, no results from any engine, an engine below a reliability threshold), Grafana dashboard |
| Access in api mode | anything that reaches it | optional NetworkPolicy: only the pods and namespaces you list (tested: listed client 200, others blocked) |

## Install

```bash
helm repo add oreonit https://oreondev.github.io/helm-charts
helm install searxng oreonit/searxng -n search --create-namespace -f searxng.yaml
```

As the search backend for Firecrawl and Open WebUI:

```yaml
mode: api
networkPolicy:
  enabled: true
  allowedPodLabels:
    - app.kubernetes.io/name: firecrawl
    - app.kubernetes.io/name: open-webui
metrics:
  enabled: true
  serviceMonitor: { enabled: true }
  prometheusRule: { enabled: true }
  dashboard: { enabled: true }
```

Then point the clients at the Service:

| Client | Setting |
|---|---|
| Firecrawl ([chart](../firecrawl)) | `firecrawl.env.SEARXNG_ENDPOINT: http://searxng.search.svc:8080` |
| Open WebUI | `SEARXNG_QUERY_URL=http://searxng.search.svc:8080/search?q=<query>` |
| LangChain | `SearxSearchWrapper(searx_host="http://searxng.search.svc:8080")` |

A public instance:

```yaml
mode: public
replicaCount: 1                 # or valkey.mode: external for one shared limit across replicas
baseUrl: https://search.example.com
ingress:
  enabled: true
  className: nginx
  hosts:
    - host: search.example.com
      paths: [{ path: /, pathType: Prefix }]
  tls:
    - secretName: search-tls
      hosts: [search.example.com]
limiter:
  trustedProxies: [10.0.0.0/8]  # the ingress controller's pod network
```

### When engines stop answering

Search engines block or CAPTCHA traffic from cloud egress addresses; DuckDuckGo did so from the test network, and upstream ships Google and Bing disabled for the same reason. The dashboard and the `SearXNGEngineUnreliable` / `SearXNGNoResults` alerts show which engine is failing. Disable it (`engines.disabled`), route engine traffic through a proxy (`outgoingProxies`), or add an engine (`engines.extra: [google]`).

Engine statistics are kept per pod (and per worker process, which is why the chart runs one Granian worker per pod and scales with replicas).

## Values

| Key | Default | |
|---|---|---|
| `mode` | `api` | or `public` |
| `formats` | by mode | `/search?format=` values |
| `secretKey` / `existingSecret` | generated | `server.secret_key` |
| `baseUrl`, `instanceName` | ingress host, `SearXNG` | |
| `engines.profile` / `.curated` / `.extra` / `.disabled` | `curated` | |
| `requestTimeout` / `maxRequestTimeout` | 3 / 8 s | per engine |
| `outgoingProxies` | | proxies for engine requests |
| `limiter.trustedProxies` / `.passIps` / `.blockIps` | private ranges | public mode |
| `valkey.mode` / `.url` / `.existingSecret` | `auto` (sidecar in public mode) | |
| `settings` | | deep-merged into `settings.yml` |
| `server.workers` / `.blockingThreads` | 1 / 8 | Granian |
| `replicaCount`, `autoscaling.*`, `podDisruptionBudget.*` | 2, off, on | |
| `resources` | 100m / 256Mi, limit 768Mi | |
| `ingress.*`, `httpRoute.*` | off | |
| `networkPolicy.enabled` / `.allowedPodLabels` / `.allowedNamespaceLabels` | off | |
| `metrics.enabled`, `.serviceMonitor`, `.prometheusRule`, `.dashboard` | off | |

Everything is validated by `values.schema.json`.

## Credits and licence

SearXNG is developed by the [SearXNG project](https://github.com/searxng/searxng) under the AGPL-3.0; the chart deploys the upstream image unmodified.

The chart is MIT licensed and maintained by [Oreon IT](https://www.oreonit.com/?utm_source=helm-chart&utm_medium=readme&utm_campaign=searxng), a DevOps, SRE and cloud consultancy in London. If you run search, crawling or RAG pipelines for AI agents on Kubernetes and want them scaled and monitored properly, [that is the day job](https://www.oreonit.com/private-llm-hosting-and-operations/?utm_source=helm-chart&utm_medium=readme&utm_campaign=searxng).
