{{- define "cw.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "cw.fullname" -}}
{{- if contains .Chart.Name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "cw.labels" -}}
helm.sh/chart: {{ include "cw.chart" . }}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{/* Alert labels: severity plus the global extra labels. Pass dict root, severity. */}}
{{- define "cw.alertLabels" -}}
severity: {{ .severity | quote }}
{{- range $k, $v := .root.Values.alertLabels }}
{{ $k }}: {{ $v | quote }}
{{- end }}
{{- end -}}
