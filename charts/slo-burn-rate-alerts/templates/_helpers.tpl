{{/*
Chart label value.
*/}}
{{- define "slo.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Name of the generated resources.
*/}}
{{- define "slo.fullname" -}}
{{- if contains .Chart.Name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{/*
Standard labels.
*/}}
{{- define "slo.labels" -}}
helm.sh/chart: {{ include "slo.chart" . }}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{/*
Comma-separated set of every short and long alert window (e.g. "1d,1h,2h,30m,3d,5m,6h").
Call with the root context.
*/}}
{{- define "slo.windows" -}}
{{- $set := dict -}}
{{- range $kind := list "page" "ticket" -}}
{{- $cfg := index $.Values.alerting $kind -}}
{{- range $w := $cfg.windows -}}
{{- $_ := set $set $w.long true -}}
{{- $_ := set $set $w.short true -}}
{{- end -}}
{{- end -}}
{{- keys $set | sortAlpha | join "," -}}
{{- end -}}

{{/*
Labels put on every rule and alert of one SLO: slo, service and the SLO's extra labels.
Call with the SLO item.
*/}}
{{- define "slo.ruleLabels" -}}
slo: {{ .name | quote }}
{{- if .service }}
service: {{ .service | quote }}
{{- end }}
{{- range $k, $v := (.labels | default dict) }}
{{ $k }}: {{ $v | quote }}
{{- end }}
{{- end -}}
