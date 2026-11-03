{{- define "searxng.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "searxng.fullname" -}}
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

{{- define "searxng.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "searxng.selectorLabels" -}}
app.kubernetes.io/name: {{ include "searxng.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "searxng.labels" -}}
helm.sh/chart: {{ include "searxng.chart" . }}
{{ include "searxng.selectorLabels" . }}
app.kubernetes.io/version: {{ include "searxng.imageTag" . | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "searxng.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "searxng.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{- define "searxng.imageTag" -}}
{{- default .Chart.AppVersion .Values.image.tag }}
{{- end }}

{{- define "searxng.image" -}}
{{- if .Values.image.digest }}
{{- printf "%s@%s" .Values.image.repository .Values.image.digest }}
{{- else }}
{{- printf "%s:%s" .Values.image.repository (include "searxng.imageTag" .) }}
{{- end }}
{{- end }}

{{/* none | sidecar | external, with auto resolved by mode. */}}
{{- define "searxng.valkeyMode" -}}
{{- if eq .Values.valkey.mode "auto" }}{{ ternary "sidecar" "none" (eq .Values.mode "public") }}
{{- else }}{{ .Values.valkey.mode }}
{{- end }}
{{- end }}

{{- define "searxng.baseUrl" -}}
{{- if .Values.baseUrl }}{{ .Values.baseUrl | trimSuffix "/" }}/
{{- else if and .Values.ingress.enabled .Values.ingress.hosts }}https://{{ (first .Values.ingress.hosts).host }}/
{{- else if and .Values.httpRoute.enabled .Values.httpRoute.hostnames }}https://{{ first .Values.httpRoute.hostnames }}/
{{- end }}
{{- end }}

{{/* settings.yml (rendered into the chart Secret: it carries the metrics password). The secret key and Valkey URL come from the environment. */}}
{{- define "searxng.settings" -}}
{{- $v := .Values -}}
{{- $public := eq $v.mode "public" -}}
{{- $formats := $v.formats | default (ternary (list "html") (list "html" "json" "csv" "rss") $public) -}}
{{- $s := dict
  "use_default_settings" true
  "general" (dict "instance_name" $v.instanceName "enable_metrics" true)
  "search" (dict "formats" $formats)
  "server" (dict "limiter" $public "public_instance" $public "image_proxy" true "method" "GET")
  "outgoing" (dict "request_timeout" $v.requestTimeout "max_request_timeout" $v.maxRequestTimeout)
-}}
{{- with include "searxng.baseUrl" . }}{{ $_ := set $s.server "base_url" . }}{{ end }}
{{- with $v.outgoingProxies }}{{ $_ := set $s.outgoing "proxies" . }}{{ end }}
{{- if eq $v.engines.profile "curated" }}
{{- $_ := set $s "use_default_settings" (dict "engines" (dict "keep_only" (concat $v.engines.curated $v.engines.extra | uniq))) }}
{{- end }}
{{- $engines := list }}
{{- range $v.engines.extra }}{{ $engines = append $engines (dict "name" . "disabled" false) }}{{ end }}
{{- range $v.engines.disabled }}{{ $engines = append $engines (dict "name" . "disabled" true) }}{{ end }}
{{- with $engines }}{{ $_ := set $s "engines" . }}{{ end }}
{{- if $v.metrics.enabled }}
{{- $_ := set $s.general "open_metrics" (get (include "searxng.secretData" . | fromYaml) "metrics-password") }}
{{- end }}
{{- mergeOverwrite $s (deepCopy ($v.settings | default dict)) | toYaml }}
{{- end }}

{{- define "searxng.limiterToml" -}}
{{- $l := .Values.limiter -}}
[botdetection]
ipv4_prefix = 32
ipv6_prefix = 48
trusted_proxies = [{{ range $i, $p := $l.trustedProxies }}{{ if $i }}, {{ end }}{{ $p | quote }}{{ end }}]

[botdetection.ip_limit]
filter_link_local = false
link_token = false

[botdetection.ip_lists]
pass_ip = [{{ range $i, $p := $l.passIps }}{{ if $i }}, {{ end }}{{ $p | quote }}{{ end }}]
block_ip = [{{ range $i, $p := $l.blockIps }}{{ if $i }}, {{ end }}{{ $p | quote }}{{ end }}]
{{- end }}

{{/* Secret values: given, else stored, else generated. Cached per render. */}}
{{- define "searxng.secretData" -}}
{{- if not (hasKey . "searxngSecretData") }}
{{- $_ := set . "searxngSecretData" (include "searxng.secretDataRender" .) }}
{{- end }}
{{- get . "searxngSecretData" }}
{{- end }}

{{- define "searxng.secretDataRender" -}}
{{- $v := .Values -}}
{{- $old := dict -}}
{{- with lookup "v1" "Secret" .Release.Namespace (include "searxng.fullname" .) }}{{ $old = .data | default dict }}{{ end -}}
{{- $data := dict -}}
{{- if not $v.existingSecret }}
{{- $_ := set $data "secret-key" (coalesce $v.secretKey (get $old "secret-key" | b64dec) (randAlphaNum 48)) }}
{{- end }}
{{- if $v.metrics.enabled }}
{{- $_ := set $data "metrics-password" (coalesce $v.metrics.password (get $old "metrics-password" | b64dec) (randAlphaNum 32)) }}
{{- end }}
{{- if and (eq (include "searxng.valkeyMode" .) "external") $v.valkey.url (not $v.valkey.existingSecret) }}
{{- $_ := set $data "valkey-url" $v.valkey.url }}
{{- end }}
{{- toYaml $data }}
{{- end }}


{{- define "searxng.validate" -}}
{{- if not (has .Values.engines.profile (list "curated" "default")) }}{{ fail "engines.profile must be curated or default" }}{{ end }}
{{- if not (has .Values.mode (list "api" "public")) }}{{ fail "mode must be api or public" }}{{ end }}
{{- if not (has .Values.valkey.mode (list "auto" "none" "sidecar" "external")) }}{{ fail "valkey.mode must be auto, none, sidecar or external" }}{{ end }}
{{- if and (eq .Values.mode "public") (eq (include "searxng.valkeyMode" .) "none") }}
{{- fail "mode=public needs Valkey for the rate limiter: set valkey.mode to sidecar or external" }}
{{- end }}
{{- end }}
