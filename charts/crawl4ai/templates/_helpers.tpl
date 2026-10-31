{{- define "crawl4ai.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "crawl4ai.fullname" -}}
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

{{- define "crawl4ai.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "crawl4ai.selectorLabels" -}}
app.kubernetes.io/name: {{ include "crawl4ai.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "crawl4ai.labels" -}}
helm.sh/chart: {{ include "crawl4ai.chart" . }}
{{ include "crawl4ai.selectorLabels" . }}
app.kubernetes.io/version: {{ include "crawl4ai.imageTag" . | quote }}
app.kubernetes.io/component: api
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "crawl4ai.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "crawl4ai.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{- define "crawl4ai.imageTag" -}}
{{- default .Chart.AppVersion .Values.image.tag }}
{{- end }}

{{- define "crawl4ai.image" -}}
{{- if .Values.image.digest }}
{{- printf "%s@%s" .Values.image.repository .Values.image.digest }}
{{- else }}
{{- printf "%s:%s" .Values.image.repository (include "crawl4ai.imageTag" .) }}
{{- end }}
{{- end }}

{{/* True ("true") when more than one pod can run. */}}
{{- define "crawl4ai.multiReplica" -}}
{{- if or .Values.autoscaling.enabled (gt (int .Values.replicaCount) 1) }}true{{ end }}
{{- end }}

{{/* Quantity (Ki, Mi, Gi, k, M, G or bytes) to bytes. */}}
{{- define "crawl4ai.bytes" -}}
{{- $q := toString . }}
{{- if hasSuffix "Gi" $q }}{{ mul (trimSuffix "Gi" $q | int64) 1073741824 }}
{{- else if hasSuffix "Mi" $q }}{{ mul (trimSuffix "Mi" $q | int64) 1048576 }}
{{- else if hasSuffix "Ki" $q }}{{ mul (trimSuffix "Ki" $q | int64) 1024 }}
{{- else if hasSuffix "G" $q }}{{ mul (trimSuffix "G" $q | int64) 1000000000 }}
{{- else if hasSuffix "M" $q }}{{ mul (trimSuffix "M" $q | int64) 1000000 }}
{{- else if hasSuffix "k" $q }}{{ mul (trimSuffix "k" $q | int64) 1000 }}
{{- else }}{{ $q | int64 }}
{{- end }}
{{- end }}

{{/* The server's config.yml: the upstream file, chart settings, then .Values.config. */}}
{{- define "crawl4ai.configYaml" -}}
{{- $base := .Files.Get "files/config.yml" | fromYaml }}
{{- $chart := dict "app" (dict "host" "0.0.0.0" "port" 11235) }}
{{- if eq .Values.redis.mode "external" }}
{{- $r := .Values.redis.external }}
{{- $scheme := ternary "rediss" "redis" $r.tls }}
{{- $_ := set $chart "redis" (dict "db" (int $r.db) "ssl" $r.tls "username" $r.username) }}
{{- $_ := set $chart "rate_limiting" (dict "storage_uri" (printf "%s://%s:%v/%v" $scheme (tpl $r.host $) $r.port $r.db)) }}
{{- end }}
{{- mergeOverwrite $base $chart (deepCopy (.Values.config | default dict)) | toYaml }}
{{- end }}

{{- define "crawl4ai.gunicornConf" -}}
{{- $g := .Values.gunicorn -}}
# Rendered by the crawl4ai chart. Replaces the image's supervisord + gunicorn command line.
bind = "[::]:11235"
workers = {{ int $g.workers }}
threads = {{ int $g.threads }}
worker_class = "uvicorn.workers.UvicornWorker"
timeout = {{ int $g.timeout }}
graceful_timeout = {{ int $g.gracefulTimeout }}
keepalive = {{ int $g.keepalive }}
limit_request_line = 8190
limit_request_fields = 100
loglevel = "info"
# The control socket (gunicorn 23+) would need a writable home directory.
control_socket_disable = True
{{- with $g.forwardedAllowIps }}
forwarded_allow_ips = {{ . | quote }}
{{- end }}


def post_worker_init(worker):
    # The egress proxy's stop() waits for every client connection to close, and Chromium keeps
    # its CONNECT tunnels open, so after the first crawl every shutdown hung for the full graceful
    # timeout and the pod was killed. Bound the wait.
    import asyncio
    import egress_proxy

    async def stop(self):
        if self._server is not None:
            self._server.close()
            try:
                await asyncio.wait_for(self._server.wait_closed(), 2)
            except Exception:
                pass

    egress_proxy.PinningProxy.stop = stop
{{- end }}

{{/* Non-secret environment. */}}
{{- define "crawl4ai.env" -}}
{{- $v := .Values -}}
{{- $env := dict
  "CRAWL4AI_ALLOW_DEEP_CRAWL" (toString $v.features.deepCrawl)
  "CRAWL4AI_HOOKS_ENABLED" (toString $v.features.hooks)
  "CRAWL4AI_EXECUTE_JS_ENABLED" (toString $v.features.executeJs)
  "CRAWL4AI_ALLOW_INTERNAL_URLS" (toString $v.features.internalUrls)
  "CRAWL4AI_CHROMIUM_SANDBOX" (toString $v.features.chromiumSandbox)
  "CRAWL4AI_ARTIFACT_TTL_SECONDS" (toString (int $v.artifacts.ttlSeconds))
  "CRAWL4AI_ARTIFACT_QUOTA_BYTES" (toString (div (mul (include "crawl4ai.bytes" $v.artifacts.size | int64) 9) 10))
  "REDIS_TASK_TTL" (toString (int $v.redis.taskTtlSeconds))
  "CRAWL4AI_NO_CLOUD_NOTICE" "1"
-}}
{{- if eq $v.redis.mode "external" }}
{{- $_ := set $env "REDIS_HOST" (tpl (required "redis.external.host is required with redis.mode=external" $v.redis.external.host) $) }}
{{- $_ := set $env "REDIS_PORT" (toString $v.redis.external.port) }}
{{- $_ := set $env "REDIS_USERNAME" $v.redis.external.username }}
{{- else }}
{{- $_ := set $env "REDIS_HOST" "127.0.0.1" }}
{{- $_ := set $env "REDIS_PORT" "6379" }}
{{- end }}
{{- with $v.llm.provider }}{{ $_ := set $env "LLM_PROVIDER" . }}{{ end }}
{{- with $v.llm.baseUrl }}{{ $_ := set $env "LLM_BASE_URL" . }}{{ end }}
{{- range $k, $val := merge (deepCopy ($v.env | default dict)) $env }}
{{ $k }}: {{ toString $val | quote }}
{{- end }}
{{- end }}

{{/* Secret values: given, else the value already stored, else generated. Cached per render. */}}
{{- define "crawl4ai.secretData" -}}
{{- if not (hasKey . "crawl4aiSecretData") }}
{{- $_ := set . "crawl4aiSecretData" (include "crawl4ai.secretDataRender" .) }}
{{- end }}
{{- get . "crawl4aiSecretData" }}
{{- end }}

{{- define "crawl4ai.secretDataRender" -}}
{{- $v := .Values -}}
{{- $old := dict -}}
{{- $found := lookup "v1" "Secret" .Release.Namespace (include "crawl4ai.fullname" .) -}}
{{- if $found }}{{ $old = $found.data | default dict }}{{ end -}}
{{- $data := dict -}}
{{- if not $v.auth.existingSecret }}
{{- $_ := set $data "CRAWL4AI_API_TOKEN" (coalesce $v.auth.apiToken (get $old "CRAWL4AI_API_TOKEN" | b64dec) (randAlphaNum 64)) }}
{{- end }}
{{- /* Signs the JWTs /token issues. Generated per pod upstream, so tokens broke on every restart
     and were rejected by every other replica. */}}
{{- $_ := set $data "SECRET_KEY" (coalesce (get $old "SECRET_KEY" | b64dec) (randAlphaNum 64)) }}
{{- if eq $v.redis.mode "sidecar" }}
{{- $_ := set $data "REDIS_PASSWORD" (coalesce (get $old "REDIS_PASSWORD" | b64dec) (randAlphaNum 32)) }}
{{- else if and $v.redis.external.password (not $v.redis.external.existingSecret) }}
{{- $_ := set $data "REDIS_PASSWORD" $v.redis.external.password }}
{{- end }}
{{- range $k, $val := $v.secretEnv }}
{{- $_ := set $data $k (toString $val) }}
{{- end }}
{{- toYaml $data }}
{{- end }}

{{/* Secret holding the API token, and its key. */}}
{{- define "crawl4ai.tokenSecretName" -}}
{{- default (include "crawl4ai.fullname" .) .Values.auth.existingSecret }}
{{- end }}
{{- define "crawl4ai.tokenSecretKey" -}}
{{- ternary .Values.auth.existingSecretKey "CRAWL4AI_API_TOKEN" (not (empty .Values.auth.existingSecret)) }}
{{- end }}

{{- define "crawl4ai.secretRefEnv" -}}
{{- $v := .Values -}}
{{- if $v.auth.existingSecret }}
- name: CRAWL4AI_API_TOKEN
  valueFrom: { secretKeyRef: { name: {{ $v.auth.existingSecret }}, key: {{ $v.auth.existingSecretKey }} } }
{{- end }}
{{- if and (eq $v.redis.mode "external") $v.redis.external.existingSecret }}
- name: REDIS_PASSWORD
  valueFrom: { secretKeyRef: { name: {{ $v.redis.external.existingSecret }}, key: {{ $v.redis.external.existingSecretKey }} } }
{{- end }}
{{- end }}

{{- define "crawl4ai.envFrom" -}}
- configMapRef:
    name: {{ include "crawl4ai.fullname" . }}-env
- secretRef:
    name: {{ include "crawl4ai.fullname" . }}
{{- with .Values.extraEnvFrom }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{- define "crawl4ai.validate" -}}
{{- if not (has .Values.redis.mode (list "sidecar" "external")) }}
{{- fail "redis.mode must be sidecar or external" }}
{{- end }}
{{- if and (include "crawl4ai.multiReplica" .) (eq .Values.redis.mode "sidecar") }}
{{- fail "more than one replica (replicaCount > 1 or autoscaling.enabled) needs redis.mode=external: with the sidecar each pod has its own job store, and a job polled on another pod is not found" }}
{{- end }}
{{- end }}
