{{- define "firecrawl.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "firecrawl.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "firecrawl.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* Pass (dict "ctx" $ "component" "api"). */}}
{{- define "firecrawl.selectorLabels" -}}
app.kubernetes.io/name: {{ include "firecrawl.name" .ctx }}
app.kubernetes.io/instance: {{ .ctx.Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end }}

{{- define "firecrawl.labels" -}}
helm.sh/chart: {{ include "firecrawl.chart" .ctx }}
{{ include "firecrawl.selectorLabels" . }}
app.kubernetes.io/version: {{ .ctx.Chart.AppVersion | quote }}
app.kubernetes.io/part-of: firecrawl
app.kubernetes.io/managed-by: {{ .ctx.Release.Service }}
{{- end }}

{{- define "firecrawl.componentName" -}}{{ include "firecrawl.fullname" .ctx }}-{{ .component }}{{- end }}

{{- define "firecrawl.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "firecrawl.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/* Pass (dict "image" .Values.x.image "default" "tag"). */}}
{{- define "firecrawl.imageRef" -}}
{{- if .image.digest }}
{{- printf "%s@%s" .image.repository .image.digest }}
{{- else }}
{{- printf "%s:%s" .image.repository (default .default .image.tag) }}
{{- end }}
{{- end }}

{{- define "firecrawl.image" -}}
{{- include "firecrawl.imageRef" (dict "image" .Values.image "default" .Chart.AppVersion) }}
{{- end }}

{{/* Memory limit in MiB ("" when unset). */}}
{{- define "firecrawl.memoryMiB" -}}
{{- $m := toString (dig "limits" "memory" "" (. | default dict)) }}
{{- if hasSuffix "Gi" $m }}{{ mul (trimSuffix "Gi" $m | int) 1024 }}
{{- else if hasSuffix "Mi" $m }}{{ trimSuffix "Mi" $m | int }}
{{- else if hasSuffix "G" $m }}{{ div (mul (trimSuffix "G" $m | int64) 1000000000) 1048576 }}
{{- else if hasSuffix "M" $m }}{{ div (mul (trimSuffix "M" $m | int64) 1000000) 1048576 }}
{{- end }}
{{- end }}

{{/* NODE_OPTIONS heap cap: 75% of the memory limit. Pass the resources map. */}}
{{- define "firecrawl.nodeOptions" -}}
{{- $mib := include "firecrawl.memoryMiB" . }}
{{- if $mib }}--max-old-space-size={{ div (mul ($mib | int) 3) 4 }}{{ end }}
{{- end }}

{{- define "firecrawl.redisName" -}}{{ include "firecrawl.fullname" . }}-redis{{- end }}
{{- define "firecrawl.postgresName" -}}{{ include "firecrawl.fullname" . }}-postgres{{- end }}
{{- define "firecrawl.playwrightName" -}}{{ include "firecrawl.fullname" . }}-playwright{{- end }}

{{- define "firecrawl.postgresHost" -}}
{{- if eq .Values.postgres.mode "bundled" }}{{ include "firecrawl.postgresName" . }}
{{- else }}{{ tpl (required "postgres.external.host is required with postgres.mode=external" .Values.postgres.external.host) . }}
{{- end }}
{{- end }}

{{- define "firecrawl.postgresPort" -}}
{{- ternary "5432" (toString .Values.postgres.external.port) (eq .Values.postgres.mode "bundled") }}
{{- end }}

{{- define "firecrawl.postgresSecretName" -}}
{{- default (include "firecrawl.fullname" .) .Values.postgres.existingSecret }}
{{- end }}
{{- define "firecrawl.postgresSecretKey" -}}
{{- ternary .Values.postgres.existingSecretKey "POSTGRES_PASSWORD" (not (empty .Values.postgres.existingSecret)) }}
{{- end }}

{{/* Non-secret environment for every Firecrawl container. */}}
{{- define "firecrawl.env" -}}
{{- $v := .Values -}}
{{- $f := $v.firecrawl -}}
{{- $env := dict
  "HOST" "0.0.0.0"
  "PORT" "3002"
  "ENV" "production"
  "IS_KUBERNETES" "true"
  "USE_DB_AUTHENTICATION" "false"
  "LOGGING_LEVEL" $f.logLevel
  "NUM_WORKERS_PER_QUEUE" (toString $f.numWorkersPerQueue)
  "CRAWL_CONCURRENT_REQUESTS" (toString $f.crawlConcurrentRequests)
  "MAX_CONCURRENT_JOBS" (toString $f.maxConcurrentJobs)
  "ALLOW_LOCAL_WEBHOOKS" (toString $f.allowLocalWebhooks)
  "BULL_AUTH_KEY_PATH_ROUTES" "false"
  "NUQ_WAIT_MODE" $f.waitMode
  "EXPRESS_TRUST_PROXY" (toString (default (ternary 2 1 $v.auth.enabled) $f.trustProxyHops))
  "POSTGRES_HOST" (include "firecrawl.postgresHost" .)
  "POSTGRES_PORT" (include "firecrawl.postgresPort" .)
  "POSTGRES_DB" $v.postgres.database
  "POSTGRES_USER" $v.postgres.user
  "WORKER_PORT" "3005"
  "EXTRACT_WORKER_PORT" "3004"
  "NUQ_WORKER_PORT" "3006"
  "NUQ_PREFETCH_WORKER_PORT" "3011"
  "NUQ_RECONCILER_WORKER_PORT" "3012"
-}}
{{- if $v.playwright.enabled }}
{{- $_ := set $env "PLAYWRIGHT_MICROSERVICE_URL" (printf "http://%s:3000/scrape" (include "firecrawl.playwrightName" .)) }}
{{- end }}
{{- if eq $v.postgres.mode "external" }}
{{- $_ := set $env "PGSSLMODE" $v.postgres.external.sslMode }}
{{- end }}
{{- if $v.metrics.enabled }}
{{- $_ := set $env "ADMIN_INTERNAL_PORT" "3010" }}
{{- $_ := set $env "ADMIN_INTERNAL_HOST" "0.0.0.0" }}
{{- end }}
{{- range $k, $val := merge (deepCopy ($f.env | default dict)) $env }}
{{ $k }}: {{ toString $val | quote }}
{{- end }}
{{- end }}

{{/* Chart Secret values: given, else stored, else generated. Cached per render. */}}
{{- define "firecrawl.secretData" -}}
{{- if not (hasKey . "firecrawlSecretData") }}
{{- $_ := set . "firecrawlSecretData" (include "firecrawl.secretDataRender" .) }}
{{- end }}
{{- get . "firecrawlSecretData" }}
{{- end }}

{{- define "firecrawl.secretDataRender" -}}
{{- $v := .Values -}}
{{- $old := dict -}}
{{- $found := lookup "v1" "Secret" .Release.Namespace (include "firecrawl.fullname" .) -}}
{{- if $found }}{{ $old = $found.data | default dict }}{{ end -}}
{{- $data := dict -}}
{{- if not $v.postgres.existingSecret }}
{{- $_ := set $data "POSTGRES_PASSWORD" (coalesce $v.postgres.password (get $old "POSTGRES_PASSWORD" | b64dec) (randAlphaNum 32)) }}
{{- end }}
{{- if eq $v.rabbitmq.mode "bundled" }}
{{- $_ := set $data "RABBITMQ_PASSWORD" (coalesce (get $old "RABBITMQ_PASSWORD" | b64dec) (randAlphaNum 32)) }}
{{- end }}
{{- /* Admin routes on the public port are switched off (BULL_AUTH_KEY_PATH_ROUTES=false; the chart uses the
     internal admin listener); a random key keeps them unguessable if someone turns them back on. */}}
{{- $_ := set $data "BULL_AUTH_KEY" (coalesce (get $old "BULL_AUTH_KEY" | b64dec) (randAlphaNum 40)) }}
{{- if and $v.auth.enabled (not $v.auth.existingSecret) }}
{{- $keys := $v.auth.apiKeys }}
{{- if not $keys }}
{{- $oldKeys := "" }}
{{- with lookup "v1" "Secret" .Release.Namespace (printf "%s-gateway-keys" (include "firecrawl.fullname" .)) }}
{{- $oldKeys = get (.data | default dict) "api-keys" | b64dec | trim }}
{{- end }}
{{- $keys = list (coalesce $oldKeys (printf "fc-%s" (randAlphaNum 32 | lower))) }}
{{- end }}
{{- $_ := set $data "api-keys" (join "\n" $keys) }}
{{- end }}
{{- range $k, $val := $v.secretEnv }}
{{- $_ := set $data $k (toString $val) }}
{{- end }}
{{- toYaml $data }}
{{- end }}

{{/* env for the queue and Redis URLs, built in the container from secret parts. */}}
{{- define "firecrawl.connectionEnv" -}}
- name: POSTGRES_PASSWORD
  valueFrom: { secretKeyRef: { name: {{ include "firecrawl.postgresSecretName" . }}, key: {{ include "firecrawl.postgresSecretKey" . }} } }
- name: NUQ_DATABASE_URL
  value: postgresql://$(POSTGRES_USER):$(POSTGRES_PASSWORD)@$(POSTGRES_HOST):$(POSTGRES_PORT)/$(POSTGRES_DB)
- name: NUQ_DATABASE_URL_LISTEN
  value: postgresql://$(POSTGRES_USER):$(POSTGRES_PASSWORD)@$(POSTGRES_HOST):$(POSTGRES_PORT)/$(POSTGRES_DB)
{{- if eq .Values.redis.mode "external" }}
{{- if .Values.redis.external.existingSecret }}
- name: REDIS_URL
  valueFrom: { secretKeyRef: { name: {{ .Values.redis.external.existingSecret }}, key: {{ .Values.redis.external.existingSecretKey }} } }
{{- else }}
- name: REDIS_URL
  value: {{ tpl (required "redis.external.url or redis.external.existingSecret is required with redis.mode=external" .Values.redis.external.url) . | quote }}
{{- end }}
{{- else }}
- name: REDIS_URL
  value: redis://{{ include "firecrawl.redisName" . }}:6379
{{- end }}
- name: REDIS_RATE_LIMIT_URL
  value: $(REDIS_URL)
{{- if eq .Values.rabbitmq.mode "bundled" }}
- name: RABBITMQ_PASSWORD
  valueFrom: { secretKeyRef: { name: {{ include "firecrawl.fullname" . }}, key: RABBITMQ_PASSWORD } }
- name: NUQ_RABBITMQ_URL
  value: amqp://firecrawl:$(RABBITMQ_PASSWORD)@{{ include "firecrawl.fullname" . }}-rabbitmq:5672
{{- else if eq .Values.rabbitmq.mode "external" }}
{{- if .Values.rabbitmq.external.existingSecret }}
- name: NUQ_RABBITMQ_URL
  valueFrom: { secretKeyRef: { name: {{ .Values.rabbitmq.external.existingSecret }}, key: {{ .Values.rabbitmq.external.existingSecretKey }} } }
{{- else }}
- name: NUQ_RABBITMQ_URL
  value: {{ tpl (required "rabbitmq.external.url is required with rabbitmq.mode=external" .Values.rabbitmq.external.url) . | quote }}
{{- end }}
{{- end }}
{{- end }}

{{- define "firecrawl.envFrom" -}}
- configMapRef:
    name: {{ include "firecrawl.fullname" . }}-env
- secretRef:
    name: {{ include "firecrawl.fullname" . }}
{{- with .Values.extraEnvFrom }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{- define "firecrawl.validate" -}}
{{- if not (has .Values.redis.mode (list "bundled" "external")) }}{{ fail "redis.mode must be bundled or external" }}{{ end }}
{{- if not (has .Values.postgres.mode (list "bundled" "external")) }}{{ fail "postgres.mode must be bundled or external" }}{{ end }}
{{- if not (has .Values.rabbitmq.mode (list "none" "bundled" "external")) }}{{ fail "rabbitmq.mode must be none, bundled or external" }}{{ end }}
{{- if and .Values.extractWorker.enabled (eq .Values.rabbitmq.mode "none") }}
{{- fail "extractWorker.enabled needs RabbitMQ: set rabbitmq.mode to bundled or external (the extract queue is AMQP only)" }}
{{- end }}
{{- if and .Values.nuqWorker.autoscaling.enabled .Values.nuqWorker.autoscaling.keda.enabled }}
{{- fail "nuqWorker.autoscaling: enable either the CPU HPA (enabled) or KEDA (keda.enabled), not both" }}
{{- end }}
{{- if and .Values.nuqWorker.autoscaling.keda.enabled (not .Values.metrics.enabled) }}
{{- fail "nuqWorker.autoscaling.keda needs metrics.enabled (it scales on the queue depth metric)" }}
{{- end }}
{{- end }}

{{/* nginx config of the token gate in the API pods. */}}
{{- define "firecrawl.gatewayConf" -}}
worker_processes 1;
pid /tmp/nginx.pid;
error_log /dev/stderr warn;
events { worker_connections 2048; }
http {
  client_body_temp_path /tmp/client_body;
  proxy_temp_path /tmp/proxy;
  fastcgi_temp_path /tmp/fastcgi;
  uwsgi_temp_path /tmp/uwsgi;
  scgi_temp_path /tmp/scgi;
  server_tokens off;
  # The key itself is never logged.
  log_format gate '$remote_addr "$request_method $uri" $status $body_bytes_sent ${request_time}s key=$fc_key_ok';
  access_log /dev/stdout gate;
  # Keep the scheme the Ingress or Gateway saw, so URLs in responses (crawl status "next") are https.
  map $http_x_forwarded_proto $fc_proto {
    default $http_x_forwarded_proto;
    "" $scheme;
  }
  map $http_authorization $fc_key_ok {
    default 0;
    include /etc/nginx/keys/keys.map;
  }
  upstream firecrawl {
    server 127.0.0.1:3002;
    keepalive 32;
  }
  server {
    listen 8080;
    client_max_body_size 50m;
    location = /healthz {
      access_log off;
      default_type text/plain;
      return 200 "ok\n";
    }
    location / {
      # Only applies to the 401 below; proxied responses keep the API's Content-Type.
      default_type application/json;
      if ($fc_key_ok = 0) {
        add_header WWW-Authenticate 'Bearer realm="firecrawl"' always;
        return 401 '{"success":false,"error":"Unauthorized: send Authorization: Bearer <API key>"}';
      }
      proxy_pass http://firecrawl;
      proxy_http_version 1.1;
      proxy_set_header Connection "";
      proxy_set_header Host $host;
      proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
      proxy_set_header X-Forwarded-Proto $fc_proto;
      proxy_read_timeout 600s;
      proxy_send_timeout 600s;
      proxy_buffering off;
    }
  }
}
{{- end }}
