{{- define "bsp.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "bsp.fullname" -}}
{{- if contains .Chart.Name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "bsp.labels" -}}
helm.sh/chart: {{ include "bsp.chart" . }}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{/*
All short and long alert windows as a comma-separated set. Call with the root context.
*/}}
{{- define "bsp.windows" -}}
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
Labels shared by a target's rules and alerts. Call with the target.
*/}}
{{- define "bsp.targetLabels" -}}
slo_target: {{ .name | quote }}
service: {{ .service | default .name | quote }}
{{- range $k, $v := (.labels | default dict) }}
{{ $k }}: {{ $v | quote }}
{{- end }}
{{- end -}}

{{/*
Recording rules for one SLO. Dict: root, target, slo (name), errorExpr (with $WINDOW), objective, windows (list), period (e.g. 30d), periodDays.
*/}}
{{- define "bsp.sloRecording" -}}
{{- $objective := divf (float64 .objective) 100 }}
{{- $budget := subf 1 $objective }}
{{- $objStr := printf "%.9g" $objective }}
{{- $budgetStr := printf "%.9g" $budget }}
{{- $sel := printf "{slo=%q}" .slo }}
{{- range $w := append .windows .period }}
- record: slo:sli_error:ratio_rate{{ $w }}
  expr: {{ $.errorExpr | replace "$WINDOW" $w }}
  labels:
    slo: {{ $.slo | quote }}
    {{- include "bsp.targetLabels" $.target | nindent 4 }}
- record: slo:error_budget_burn_rate:ratio_rate{{ $w }}
  expr: slo:sli_error:ratio_rate{{ $w }}{{ $sel }} / {{ $budgetStr }}
  labels:
    slo: {{ $.slo | quote }}
    {{- include "bsp.targetLabels" $.target | nindent 4 }}
{{- end }}
- record: slo:objective:ratio
  expr: vector({{ $objStr }})
  labels:
    slo: {{ .slo | quote }}
    {{- include "bsp.targetLabels" .target | nindent 4 }}
- record: slo:error_budget:ratio
  expr: vector({{ $budgetStr }})
  labels:
    slo: {{ .slo | quote }}
    {{- include "bsp.targetLabels" .target | nindent 4 }}
- record: slo:period:days
  expr: vector({{ .periodDays }})
  labels:
    slo: {{ .slo | quote }}
    {{- include "bsp.targetLabels" .target | nindent 4 }}
- record: slo:error_budget_remaining:ratio
  expr: 1 - (slo:sli_error:ratio_rate{{ .period }}{{ $sel }} / {{ $budgetStr }})
  labels:
    slo: {{ .slo | quote }}
    {{- include "bsp.targetLabels" .target | nindent 4 }}
{{- end -}}

{{/*
Burn-rate alerts for one SLO. Dict: root, target, slo, objective, what (availability|latency), periodDays.
*/}}
{{- define "bsp.sloAlerts" -}}
{{- $root := .root }}
{{- $sel := printf "{slo=%q}" .slo }}
{{- $periodHours := mulf (float64 .periodDays) 24 }}
{{- range $kind := list "page" "ticket" }}
{{- $cfg := index $root.Values.alerting $kind }}
{{- if $cfg.enabled }}
{{- $first := index $cfg.windows 0 }}
- alert: {{ $root.Values.alerting.alertNamePrefix }}BurnRate{{ $kind | title }}
  expr: |
    {{- range $i, $w := $cfg.windows }}
    {{- if $i }}
    or
    {{- end }}
    (
      slo:error_budget_burn_rate:ratio_rate{{ $w.long }}{{ $sel }} > {{ $w.factor }}
      and
      slo:error_budget_burn_rate:ratio_rate{{ $w.short }}{{ $sel }} > {{ $w.factor }}
    )
    {{- end }}
  for: {{ $cfg.for }}
  labels:
    severity: {{ $cfg.severity | quote }}
    slo_alert_type: {{ $kind | quote }}
    slo: {{ $.slo | quote }}
    {{- include "bsp.targetLabels" $.target | nindent 4 }}
    {{- range $k, $v := $root.Values.alerting.labels }}
    {{ $k }}: {{ $v | quote }}
    {{- end }}
  annotations:
    summary: 'Synthetic {{ $.what }} SLO for {{ $.target.name }} is burning error budget at {{ `{{ $value | printf "%.1f" }}` }}x ({{ $kind }})'
    description: >-
      {{ $.target.url }}: the {{ $.what }} SLO {{ $.slo }} ({{ printf "%.9g" (float64 $.objective) }}% over {{ $.periodDays }} days) is failing faster than its budget allows.
      At {{ $first.factor }}x the whole budget is gone in about {{ printf "%.0f" (divf $periodHours (float64 $first.factor)) }} hours.
    {{- range $k, $v := $root.Values.alerting.annotations }}
    {{ $k }}: {{ $v | quote }}
    {{- end }}
{{- end }}
{{- end }}
{{- end -}}
