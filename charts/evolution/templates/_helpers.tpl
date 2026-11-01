{{- define "evolution.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "evolution.fullname" -}}
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

{{- define "evolution.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* Selector labels: unchanged from chart 0.1.0, because a Deployment selector cannot be changed in place. */}}
{{- define "evolution.selectorLabels" -}}
app.kubernetes.io/name: {{ include "evolution.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "evolution.labels" -}}
helm.sh/chart: {{ include "evolution.chart" . }}
{{ include "evolution.selectorLabels" . }}
app.kubernetes.io/version: {{ include "evolution.imageTag" . | quote }}
app.kubernetes.io/component: api
app.kubernetes.io/part-of: evolution-api
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "evolution.serviceName" -}}
{{- default (include "evolution.fullname" .) .Values.service.name }}
{{- end }}

{{- define "evolution.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "evolution.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{- define "evolution.imageTag" -}}
{{- default (printf "v%s" .Chart.AppVersion) .Values.image.tag }}
{{- end }}

{{- define "evolution.image" -}}
{{- if .Values.image.digest }}
{{- printf "%s@%s" .Values.image.repository .Values.image.digest }}
{{- else }}
{{- printf "%s:%s" .Values.image.repository (include "evolution.imageTag" .) }}
{{- end }}
{{- end }}

{{/* SERVER_URL: explicit, else the first public host, else the Service. */}}
{{- define "evolution.serverUrl" -}}
{{- if .Values.serverUrl }}
{{- .Values.serverUrl | trimSuffix "/" }}
{{- else if and .Values.ingress.enabled .Values.ingress.hosts }}
{{- printf "https://%s" (first .Values.ingress.hosts).host }}
{{- else if and .Values.httpRoute.enabled .Values.httpRoute.hostnames }}
{{- printf "https://%s" (first .Values.httpRoute.hostnames) }}
{{- else }}
{{- printf "http://%s.%s.svc:%v" (include "evolution.serviceName" .) .Release.Namespace .Values.service.port }}
{{- end }}
{{- end }}

{{/* Memory limit in MiB (Mi, Gi, M, G or bytes), "" when unset. */}}
{{- define "evolution.memoryLimitMiB" -}}
{{- $m := toString (dig "limits" "memory" "" (.Values.resources | default dict)) }}
{{- if hasSuffix "Gi" $m }}{{ mul (trimSuffix "Gi" $m | int) 1024 }}
{{- else if hasSuffix "Mi" $m }}{{ trimSuffix "Mi" $m | int }}
{{- else if hasSuffix "G" $m }}{{ div (mul (trimSuffix "G" $m | int64) 1000000000) 1048576 }}
{{- else if hasSuffix "M" $m }}{{ div (mul (trimSuffix "M" $m | int64) 1000000) 1048576 }}
{{- else if regexMatch "^[0-9]+$" $m }}{{ div ($m | int64) 1048576 }}
{{- end }}
{{- end }}

{{- define "evolution.maxOldSpaceMB" -}}
{{- if .Values.nodeMaxOldSpaceMB }}
{{- .Values.nodeMaxOldSpaceMB }}
{{- else }}
{{- $lim := include "evolution.memoryLimitMiB" . }}
{{- if $lim }}{{ div (mul ($lim | int) 3) 4 }}{{ end }}
{{- end }}
{{- end }}

{{/* The non-secret environment, chart defaults overridden by .Values.config. */}}
{{- define "evolution.env" -}}
{{- $v := .Values -}}
{{- $s := $v.database.save -}}
{{- $env := dict
  "SERVER_TYPE" "http"
  "SERVER_PORT" "8080"
  "SERVER_URL" (include "evolution.serverUrl" .)
  "SERVER_DISABLE_MANAGER" (ternary "false" "true" $v.manager.enabled)
  "AUTHENTICATION_EXPOSE_IN_FETCH_INSTANCES" (toString $v.auth.exposeInFetchInstances)
  "DATABASE_PROVIDER" $v.database.provider
  "DATABASE_CONNECTION_CLIENT_NAME" $v.database.clientName
  "DATABASE_SAVE_DATA_INSTANCE" (toString $s.instance)
  "DATABASE_SAVE_DATA_NEW_MESSAGE" (toString $s.newMessage)
  "DATABASE_SAVE_MESSAGE_UPDATE" (toString $s.messageUpdate)
  "DATABASE_SAVE_DATA_CONTACTS" (toString $s.contacts)
  "DATABASE_SAVE_DATA_CHATS" (toString $s.chats)
  "DATABASE_SAVE_DATA_LABELS" (toString $s.labels)
  "DATABASE_SAVE_DATA_HISTORIC" (toString $s.historic)
  "DATABASE_SAVE_IS_ON_WHATSAPP" (toString $s.isOnWhatsapp)
  "DATABASE_SAVE_IS_ON_WHATSAPP_DAYS" (toString $s.isOnWhatsappDays)
  "DATABASE_DELETE_MESSAGE" (toString $v.database.deleteMessage)
  "CACHE_REDIS_ENABLED" (toString $v.redis.enabled)
  "CACHE_REDIS_PREFIX_KEY" $v.redis.prefix
  "CACHE_REDIS_TTL" (toString $v.redis.ttl)
  "CACHE_REDIS_SAVE_INSTANCES" (toString $v.redis.saveInstances)
  "CACHE_LOCAL_ENABLED" (toString (not $v.redis.enabled))
  "PROMETHEUS_METRICS" (toString $v.metrics.enabled)
-}}
{{- if $v.metrics.enabled }}
{{- $_ := set $env "METRICS_AUTH_REQUIRED" "true" }}
{{- $_ := set $env "METRICS_USER" $v.metrics.username }}
{{- end }}
{{- $merged := merge (deepCopy ($v.config | default dict)) (deepCopy ($v.defaults | default dict)) $env }}
{{- range $k, $val := $merged }}
{{ $k }}: {{ toString $val | quote }}
{{- end }}
{{- end }}

{{/* Secret values: given, else the value already stored, else generated. */}}
{{- define "evolution.secretData" -}}
{{- if not (hasKey . "evolutionSecretData") }}
{{- $_ := set . "evolutionSecretData" (include "evolution.secretDataRender" .) }}
{{- end }}
{{- get . "evolutionSecretData" }}
{{- end }}

{{/* Rendered once per release render (cached above) so generated values agree everywhere. */}}
{{- define "evolution.secretDataRender" -}}
{{- $v := .Values -}}
{{- $old := dict -}}
{{- $found := lookup "v1" "Secret" .Release.Namespace (include "evolution.fullname" .) -}}
{{- if $found }}{{ $old = $found.data | default dict }}{{ end -}}
{{- $data := dict -}}
{{- if not $v.auth.existingSecret }}
{{- $_ := set $data "AUTHENTICATION_API_KEY" (coalesce $v.auth.apiKey (get $old "AUTHENTICATION_API_KEY" | b64dec) (randAlphaNum 32)) }}
{{- end }}
{{- if and $v.database.uri (not $v.database.existingSecret) }}
{{- $_ := set $data "DATABASE_CONNECTION_URI" (tpl $v.database.uri $) }}
{{- end }}
{{- if and $v.database.migrations.uri (not $v.database.migrations.existingSecret) }}
{{- $_ := set $data "DATABASE_MIGRATION_URI" (tpl $v.database.migrations.uri $) }}
{{- end }}
{{- if and $v.redis.enabled $v.redis.uri (not $v.redis.existingSecret) }}
{{- $_ := set $data "CACHE_REDIS_URI" (tpl $v.redis.uri $) }}
{{- end }}
{{- if and $v.metrics.enabled (not $v.metrics.existingSecret) }}
{{- $_ := set $data "METRICS_PASSWORD" (coalesce $v.metrics.password (get $old "METRICS_PASSWORD" | b64dec) (randAlphaNum 32)) }}
{{- end }}
{{- range $k, $val := $v.secretEnv }}
{{- $_ := set $data $k (toString $val) }}
{{- end }}
{{- toYaml $data }}
{{- end }}

{{/* env entries for values held in user Secrets. */}}
{{- define "evolution.secretRefEnv" -}}
{{- $v := .Values -}}
{{- if $v.auth.existingSecret }}
- name: AUTHENTICATION_API_KEY
  valueFrom: { secretKeyRef: { name: {{ $v.auth.existingSecret }}, key: {{ $v.auth.existingSecretKey }} } }
{{- end }}
{{- if $v.database.existingSecret }}
- name: DATABASE_CONNECTION_URI
  valueFrom: { secretKeyRef: { name: {{ $v.database.existingSecret }}, key: {{ $v.database.existingSecretKey }} } }
{{- end }}
{{- if and $v.redis.enabled $v.redis.existingSecret }}
- name: CACHE_REDIS_URI
  valueFrom: { secretKeyRef: { name: {{ $v.redis.existingSecret }}, key: {{ $v.redis.existingSecretKey }} } }
{{- end }}
{{- if and $v.metrics.enabled $v.metrics.existingSecret }}
- name: METRICS_PASSWORD
  valueFrom: { secretKeyRef: { name: {{ $v.metrics.existingSecret }}, key: {{ $v.metrics.existingSecretKey }} } }
{{- end }}
{{- end }}

{{- define "evolution.envFrom" -}}
- configMapRef:
    name: {{ include "evolution.fullname" . }}-env
- secretRef:
    name: {{ include "evolution.fullname" . }}
{{- with .Values.extraEnvFrom }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{- define "evolution.validate" -}}
{{- if and (not .Values.redis.enabled) (not .Values.persistence.enabled) }}
{{- fail "redis.enabled=false keeps the WhatsApp signal keys in /evolution/instances: set persistence.enabled=true, or they are lost on every restart (phones logged out)" }}
{{- end }}
{{- if not (has .Values.database.provider (list "postgresql" "mysql")) }}
{{- fail "database.provider must be postgresql or mysql (for PgBouncer use postgresql with a pgbouncer=true URI and database.migrations.uri)" }}
{{- end }}
{{- end }}
