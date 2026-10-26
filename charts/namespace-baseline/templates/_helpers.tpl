{{/*
Chart label value.
*/}}
{{- define "nsb.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Standard labels. Call with the root context.
*/}}
{{- define "nsb.labels" -}}
helm.sh/chart: {{ include "nsb.chart" . }}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{/*
RoleBinding subjects from a list of Group-name strings and/or subject maps.
*/}}
{{- define "nsb.subjects" -}}
{{- range . }}
{{- if eq (kindOf .) "string" }}
- kind: Group
  name: {{ . | quote }}
  apiGroup: rbac.authorization.k8s.io
{{- else }}
- kind: {{ .kind | default "Group" }}
  name: {{ .name | quote }}
  {{- if eq (.kind | default "Group") "ServiceAccount" }}
  namespace: {{ .namespace | quote }}
  {{- else }}
  apiGroup: rbac.authorization.k8s.io
  {{- end }}
{{- end }}
{{- end }}
{{- end -}}

{{/*
A namespace peer entry (string or map) rendered as a NetworkPolicyPeer plus optional ports.
Pass a dict with "peer" and "direction" (from|to).
*/}}
{{- define "nsb.peerRule" -}}
{{- $p := .peer -}}
{{- if eq (kindOf $p) "string" -}}
- {{ .direction }}:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: {{ $p | quote }}
{{- else -}}
- {{ .direction }}:
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: {{ $p.namespace | quote }}
      {{- with $p.podLabels }}
      podSelector:
        matchLabels:
          {{- toYaml . | nindent 10 }}
      {{- end }}
  {{- with $p.ports }}
  ports:
    {{- toYaml . | nindent 4 }}
  {{- end }}
{{- end }}
{{- end -}}
