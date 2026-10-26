{{- define "kpp.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "kpp.labels" -}}
helm.sh/chart: {{ include "kpp.chart" . }}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{/*
Exclude block shared by every rule. Call with the root context.
*/}}
{{- define "kpp.exclude" -}}
{{- with .Values.excludeNamespaces -}}
exclude:
  any:
    - resources:
        namespaces:
          {{- toYaml . | nindent 10 }}
{{- end }}
{{- end -}}

{{/*
failureAction and per-namespace Enforce overrides (Kyverno >= 1.13). Call with the root context.
*/}}
{{- define "kpp.failure" -}}
failureAction: {{ .Values.failureAction }}
{{- with .Values.enforceNamespaces }}
failureActionOverrides:
  - action: Enforce
    namespaces:
      {{- toYaml . | nindent 6 }}
{{- end }}
{{- end -}}

{{/*
Standard policy annotations. Call with a dict: root, title, category, severity, subject, description.
*/}}
{{- define "kpp.annotations" -}}
policies.kyverno.io/title: {{ .title | quote }}
policies.kyverno.io/category: {{ .category | default "Production readiness" | quote }}
policies.kyverno.io/severity: {{ .severity | default "medium" | quote }}
policies.kyverno.io/subject: {{ .subject | quote }}
policies.kyverno.io/description: {{ .description | quote }}
{{- end -}}
