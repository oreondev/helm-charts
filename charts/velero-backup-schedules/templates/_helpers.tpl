{{- define "vbs.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "vbs.fullname" -}}
{{- if contains .Chart.Name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "vbs.labels" -}}
helm.sh/chart: {{ include "vbs.chart" . }}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "vbs.restoreTestName" -}}
{{- printf "%s-restore-test" (include "vbs.fullname" .) | trunc 52 | trimSuffix "-" -}}
{{- end -}}

{{- define "vbs.restoreTestServiceAccount" -}}
{{- .Values.restoreTest.serviceAccount.name | default (include "vbs.restoreTestName" .) -}}
{{- end -}}
