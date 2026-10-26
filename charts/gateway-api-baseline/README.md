# gateway-api-baseline

The shared-ingress setup we put on every cluster, as values: one [Gateway API](https://gateway-api.sigs.k8s.io/) Gateway owned by the platform team, routes owned by application teams, and the glue that otherwise gets hand-written and forgotten.

- **Gateway** with an HTTP listener that 301-redirects to HTTPS and HTTPS listeners either for any hostname or one per hostname (so cert-manager issues one certificate each, wildcards included). Routes attach from namespaces that carry a label, from the same namespace, or from anywhere.
- **HTTPRoutes and GRPCRoutes** from a list. Rules are the Gateway API rules verbatim; the chart fills in request timeouts and a `ResponseHeaderModifier` with HSTS, `X-Content-Type-Options`, `X-Frame-Options` and `Referrer-Policy` (merged into a modifier you already have, skipped on redirect rules).
- **ReferenceGrants** generated for every cross-namespace reference you make: a TLS Secret in `cert-manager`, a backend Service in another team's namespace.
- **Default backend** route for hostnames nobody claims, so strangers get your 404 page instead of the load balancer's.
- **BackendTLSPolicies** for backends that serve HTTPS.

The chart installs no controller. It works with any conformant implementation; we run it on GKE Gateway, Envoy Gateway, NGINX Gateway Fabric, Istio and Cilium.

## Install

```bash
helm repo add oreonit https://oreonit.github.io/helm-charts
kubectl create namespace gateway-system
helm install gateway oreonit/gateway-api-baseline -n gateway-system -f gateway.yaml
kubectl label namespace web shared-gateway-access=true
```

`gateway.yaml`:

```yaml
gatewayClassName: gke-l7-global-external-managed      # kubectl get gatewayclass
gateway:
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod   # one cert per HTTPS listener
  addresses: [{type: NamedAddress, value: prod-gateway-ip}]
  listeners:
    https:
      hostnames:
        - "*.example.com"
        - example.com
      tls:
        certificateRefs: [{name: wildcard-example-com-tls}]

routes:
  - name: web
    namespace: web
    hostnames: [www.example.com]
    rules:
      - matches: [{path: {type: PathPrefix, value: /}}]
        backendRefs: [{name: web, port: 80}]
      - matches: [{path: {type: PathPrefix, value: /api}}]
        backendRefs:
          - {name: api, namespace: api, port: 8080, weight: 90}
          - {name: api-canary, namespace: api, port: 8080, weight: 10}
        timeouts: {request: 10s}
  - name: apex
    namespace: web
    hostnames: [example.com]
    rules:
      - filters:
          - type: RequestRedirect
            requestRedirect: {hostname: www.example.com, statusCode: 301}
```

That renders a Gateway with listeners `http`, `https-wildcard-example-com` and `https-example-com`, two HTTPRoutes in `web` attached to the listener that matches their hostnames, a ReferenceGrant in `api` allowing HTTPRoutes from `web` to reach `api` and `api-canary`, and the redirect route. See [examples/multi-team.yaml](examples/multi-team.yaml) for the full multi-namespace layout with the default backend and a BackendTLSPolicy.

Check the Gateway is programmed, then the routes are accepted:

```bash
kubectl -n gateway-system get gateway
kubectl get httproute -A -o custom-columns='NS:.metadata.namespace,NAME:.metadata.name,ACCEPTED:.status.parents[*].conditions[?(@.type=="Accepted")].status'
```

## How routes find their listener

`routeDefaults.sectionName: https` (the default) means "the chart's HTTPS listener(s) that match this route's hostnames". With one wildcard-free `https` listener that is simply `sectionName: https`. With `listeners.https.hostnames` set, the chart compares each route hostname with each listener hostname (exact or wildcard, either side) and emits one `parentRef` per matching listener; a route whose hostnames match nothing fails the render with a message instead of silently never being programmed. Set `sectionName: http`, a literal listener name, or `""` per route to attach elsewhere, or give the route raw `parentRefs`.

## Values

| Key | Default | Description |
|---|---|---|
| `gatewayClassName` | `""` (required) | Class owned by your controller |
| `apiVersions.*` | v1 / v1beta1 / v1 | API versions for Gateway and routes, ReferenceGrant, BackendTLSPolicy |
| `gateway.enabled` | `true` | Create the Gateway; `false` to only create routes against an existing one named by `gateway.name` / `gateway.namespace` |
| `gateway.name` / `gateway.namespace` | release / release ns | Where the Gateway lives |
| `gateway.annotations` / `labels` | `{}` | e.g. `cert-manager.io/cluster-issuer`, `networking.gke.io/certmap` |
| `gateway.infrastructure.{labels,annotations,parametersRef}` | `{}` | Passed to the load balancer the controller creates |
| `gateway.addresses` | `[]` | Static addresses (`NamedAddress` on GKE, `IPAddress` elsewhere) |
| `gateway.listeners.http.{enabled,port,hostname,redirectToHttps}` | on / 80 / any / on | HTTP listener; with the redirect on, only the redirect route may attach to it |
| `gateway.listeners.https.{enabled,port,hostnames}` | on / 443 / `[]` | One listener for any hostname, or one per entry (string, or `{hostname, certificateRefs}`) |
| `gateway.listeners.https.tls.{mode,certificateRefs,options}` | Terminate / `[]` / `{}` | Shared TLS config; cross-namespace Secret refs get a ReferenceGrant |
| `gateway.listeners.extra` | `[]` | Raw listeners (TLS passthrough, TCP, UDP) |
| `gateway.allowedRoutes.{from,selector}` | Selector / `shared-gateway-access: "true"` | Which namespaces may attach routes |
| `gateway.extraSpec` | `{}` | Merged into the Gateway spec |
| `routeDefaults.{namespace,sectionName,timeouts,securityHeaders,labels,annotations}` | release ns / https / 30s / on | Defaults every route inherits |
| `securityHeaders` | HSTS, nosniff, DENY, strict-origin-when-cross-origin | Headers set on responses |
| `routes[]` | `[]` | `name`, `kind` (HTTPRoute default, GRPCRoute), `namespace`, `hostnames`, `rules`, plus per-route overrides of the defaults and raw `parentRefs` |
| `defaultBackend.{enabled,name,namespace,port}` | off | Catch-all backend for unclaimed hostnames |
| `referenceGrants.auto` / `extra` | `true` / `[]` | Generated grants; raw extra grants |
| `backendTLSPolicies[]` | `[]` | `service`, `sectionName`, `hostname`, `wellKnownCACertificates` or `caCertificateRefs` |

## Notes

- Gateway API 1.2 or newer, standard channel. BackendTLSPolicy needs 1.4+. `kubectl get crd gateways.gateway.networking.k8s.io -o jsonpath='{.metadata.annotations.gateway\.networking\.k8s\.io/bundle-version}'` prints the installed version.
- Namespace-scoped attachment is the point of the Selector default: a team cannot hijack a hostname from a namespace that is not labelled. `All` is fine on single-team clusters.
- cert-manager's Gateway solver issues one Certificate per HTTPS listener using the listener's `certificateRefs[0].name` as the Secret name, so per-hostname listeners each need a distinct ref. On GKE use Certificate Manager (`networking.gke.io/certmap`) and leave `certificateRefs` empty.
- Weighted `backendRefs` are the canary mechanism; shift the weights with a values change, no Argo Rollouts needed for simple cases.
- `timeouts.request` is core in the API but implementations vary in what they do with `backendRequest`; check your controller's conformance report.
- Security headers are response-level and do not include `Content-Security-Policy`; that belongs to the application.

This is the ingress half of our [Kubernetes production readiness checklist](https://www.oreonit.com/kubernetes-production-readiness-checklist/); [namespace-baseline](../namespace-baseline) is the per-team half. If you would like the whole platform reviewed, see our [production readiness audit](https://www.oreonit.com/production-readiness-audit-for-kubernetes/) or [Kubernetes platform engineering](https://www.oreonit.com/containerization-orchestration-management-kubernetes-openshift/) services.

## Licence

MIT. Maintained by [Oreon IT](https://www.oreonit.com/).
