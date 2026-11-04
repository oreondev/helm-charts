{{- define "mem0.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "mem0.fullname" -}}
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

{{- define "mem0.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* Selector labels; pass (dict "ctx" $ "component" "server"). */}}
{{- define "mem0.selectorLabels" -}}
app.kubernetes.io/name: {{ include "mem0.name" .ctx }}
app.kubernetes.io/instance: {{ .ctx.Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end }}

{{- define "mem0.labels" -}}
helm.sh/chart: {{ include "mem0.chart" .ctx }}
{{ include "mem0.selectorLabels" . }}
app.kubernetes.io/version: {{ .ctx.Chart.AppVersion | quote }}
app.kubernetes.io/part-of: mem0
app.kubernetes.io/managed-by: {{ .ctx.Release.Service }}
{{- end }}

{{- define "mem0.serverName" -}}{{ include "mem0.fullname" . }}-server{{- end }}
{{- define "mem0.dashboardName" -}}{{ include "mem0.fullname" . }}-dashboard{{- end }}

{{- define "mem0.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "mem0.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/* Image reference; pass (dict "ctx" $ "image" .Values.image.server). */}}
{{- define "mem0.image" -}}
{{- if .image.digest }}
{{- printf "%s@%s" .image.repository .image.digest }}
{{- else }}
{{- printf "%s:%s" .image.repository (default .ctx.Chart.AppVersion .image.tag) }}
{{- end }}
{{- end }}

{{- define "mem0.apiUrl" -}}
{{- if .Values.apiUrl }}{{ .Values.apiUrl | trimSuffix "/" }}
{{- else if .Values.ingress.enabled }}https://{{ .Values.ingress.api.host }}
{{- else if and .Values.httpRoute.enabled .Values.httpRoute.api.hostnames }}https://{{ first .Values.httpRoute.api.hostnames }}
{{- else }}http://localhost:8000
{{- end }}
{{- end }}

{{- define "mem0.dashboardUrl" -}}
{{- if .Values.dashboardUrl }}{{ .Values.dashboardUrl | trimSuffix "/" }}
{{- else if .Values.ingress.enabled }}https://{{ .Values.ingress.dashboard.host }}
{{- else if and .Values.httpRoute.enabled .Values.httpRoute.dashboard.hostnames }}https://{{ first .Values.httpRoute.dashboard.hostnames }}
{{- else }}http://localhost:3000
{{- end }}
{{- end }}

{{/* Non-secret server environment. */}}
{{- define "mem0.env" -}}
{{- $v := .Values -}}
{{- $env := dict
  "POSTGRES_HOST" (tpl (required "database.host is required" $v.database.host) $)
  "POSTGRES_PORT" (toString $v.database.port)
  "POSTGRES_USER" $v.database.user
  "POSTGRES_DB" $v.database.name
  "APP_DB_NAME" $v.database.appName
  "POSTGRES_COLLECTION_NAME" $v.database.collection
  "POSTGRES_MAINTENANCE_DB" $v.database.maintenanceDatabase
  "MEM0_CREATE_DATABASES" (toString $v.database.createDatabases)
  "PGSSLMODE" $v.database.sslMode
  "MEM0_DEFAULT_LLM_MODEL" $v.llm.model
  "MEM0_DEFAULT_EMBEDDER_MODEL" $v.llm.embedderModel
  "DASHBOARD_URL" (include "mem0.dashboardUrl" .)
  "MEM0_TELEMETRY" (toString $v.telemetry)
  "AUTH_DISABLED" "false"
  "METRICS_PORT" (ternary "9090" "0" $v.metrics.enabled)
  "REQUEST_LOG_RETENTION_DAYS" (toString $v.requestLogPruning.retentionDays)
-}}
{{- with $v.llm.openaiBaseUrl }}{{ $_ := set $env "OPENAI_BASE_URL" (tpl . $) }}{{ end }}
{{- with $v.server.forwardedAllowIps }}{{ $_ := set $env "FORWARDED_ALLOW_IPS" . }}{{ end }}
{{- with $v.auth.admin.email }}
{{- $_ := set $env "ADMIN_EMAIL" . }}
{{- $_ := set $env "ADMIN_NAME" $v.auth.admin.name }}
{{- end }}
{{- range $k, $val := merge (deepCopy ($v.env | default dict)) $env }}
{{ $k }}: {{ toString $val | quote }}
{{- end }}
{{- end }}

{{/* Secret values: given, else the value already stored, else generated. Cached per render. */}}
{{- define "mem0.secretData" -}}
{{- if not (hasKey . "mem0SecretData") }}
{{- $_ := set . "mem0SecretData" (include "mem0.secretDataRender" .) }}
{{- end }}
{{- get . "mem0SecretData" }}
{{- end }}

{{- define "mem0.secretDataRender" -}}
{{- $v := .Values -}}
{{- $old := dict -}}
{{- $found := lookup "v1" "Secret" .Release.Namespace (include "mem0.fullname" .) -}}
{{- if $found }}{{ $old = $found.data | default dict }}{{ end -}}
{{- $data := dict -}}
{{- if not $v.auth.existingSecret }}
{{- $_ := set $data "JWT_SECRET" (coalesce $v.auth.jwtSecret (get $old "JWT_SECRET" | b64dec) (randAlphaNum 64)) }}
{{- $_ := set $data "ADMIN_API_KEY" (coalesce $v.auth.adminApiKey (get $old "ADMIN_API_KEY" | b64dec) (printf "m0admin_%s" (randAlphaNum 40))) }}
{{- end }}
{{- if $v.auth.admin.email }}
{{- $_ := set $data "ADMIN_PASSWORD" (coalesce $v.auth.admin.password (get $old "ADMIN_PASSWORD" | b64dec) (randAlphaNum 24)) }}
{{- end }}
{{- if and $v.database.password (not $v.database.existingSecret) }}
{{- $_ := set $data "POSTGRES_PASSWORD" $v.database.password }}
{{- end }}
{{- range $k, $val := $v.secretEnv }}
{{- $_ := set $data $k (toString $val) }}
{{- end }}
{{- toYaml $data }}
{{- end }}

{{- define "mem0.secretRefEnv" -}}
{{- $v := .Values -}}
{{- if $v.database.existingSecret }}
- name: POSTGRES_PASSWORD
  valueFrom: { secretKeyRef: { name: {{ $v.database.existingSecret }}, key: {{ $v.database.existingSecretKey }} } }
{{- end }}
{{- if $v.auth.existingSecret }}
- name: JWT_SECRET
  valueFrom: { secretKeyRef: { name: {{ $v.auth.existingSecret }}, key: {{ $v.auth.jwtSecretKey }} } }
- name: ADMIN_API_KEY
  valueFrom: { secretKeyRef: { name: {{ $v.auth.existingSecret }}, key: {{ $v.auth.adminApiKeyKey }}, optional: true } }
{{- end }}
{{- end }}

{{- define "mem0.envFrom" -}}
- configMapRef:
    name: {{ include "mem0.fullname" . }}-env
- secretRef:
    name: {{ include "mem0.fullname" . }}
{{- with .Values.extraEnvFrom }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{/* env + envFrom block for every server-image container. */}}
{{- define "mem0.serverEnvBlock" -}}
envFrom:
  {{- include "mem0.envFrom" . | nindent 2 }}
{{- $envs := include "mem0.secretRefEnv" . | trim }}
{{- if or $envs .Values.extraEnv }}
env:
  {{- with $envs }}
  {{- . | nindent 2 }}
  {{- end }}
  {{- with .Values.extraEnv }}
  {{- toYaml . | nindent 2 }}
  {{- end }}
{{- end }}
{{- end }}

{{- define "mem0.validate" -}}
{{- $p := .Values.server.persistence }}
{{- if and (gt (int .Values.server.replicaCount) 1) $p.enabled }}
{{- fail "server.replicaCount > 1 needs server.persistence.enabled=false: the memory history is a SQLite file, which must not be shared between pods (each pod then keeps its own history)" }}
{{- end }}
{{- if not (or .Values.database.password .Values.database.existingSecret) }}
{{- fail "set database.password or database.existingSecret" }}
{{- end }}
{{- end }}
