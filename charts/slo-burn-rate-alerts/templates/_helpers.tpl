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

{{/*
Every SLO the chart renders: `slos` as written, then each OpenSLO v1 SLO in `openslo` converted to the same shape.
Returns a YAML list; callers use `include "slo.all" . | fromYamlArray`.

OpenSLO support (openslo/v1, kind SLO with an inline `indicator` or an `indicatorRef` to a kind SLI in the same list):
  - budgetingMethod Occurrences, one objective (`target` or `targetPercent`), a rolling timeWindow equal to sloPeriodDays;
  - ratioMetric with good/total or bad/total, metricSource type Prometheus (or no type);
  - the PromQL in metricSource.spec.query, with the range written as $WINDOW or Sloth's {{.window}}. A query without
    a range placeholder must be a plain counter selector and `counter: true`; it becomes sum(rate(<selector>[$WINDOW])).
  - alertPolicies are not read: alerting comes from the chart's `alerting` values.
Anything else fails the render with the reason, rather than producing rules that measure something else.
*/}}
{{- define "slo.all" -}}
{{- $out := list -}}
{{- range $s := (.Values.slos | default list) }}{{ $out = append $out $s }}{{ end -}}
{{- $src := .Values.openslo | default list -}}
{{- $docs := list -}}
{{- if kindIs "string" $src -}}
  {{- range $part := regexSplit "(?m)^---[ \\t]*$" $src -1 -}}
    {{- if trim $part -}}
      {{- $y := fromYaml $part -}}
      {{- if hasKey $y "Error" }}{{ fail (printf "openslo: cannot parse a document: %s" $y.Error) }}{{ end -}}
      {{- if $y }}{{ $docs = append $docs $y }}{{ end -}}
    {{- end -}}
  {{- end -}}
{{- else -}}
  {{- $docs = $src -}}
{{- end -}}
{{- $slis := dict -}}
{{- range $d := $docs -}}
  {{- if ne ($d.apiVersion | default "") "openslo/v1" }}{{ fail (printf "openslo: only apiVersion openslo/v1 is supported (got %q in %q)" ($d.apiVersion | default "") (dig "metadata" "name" "?" $d)) }}{{ end -}}
  {{- if eq $d.kind "SLI" }}{{ $_ := set $slis $d.metadata.name $d.spec }}{{ end -}}
{{- end -}}
{{- range $d := $docs -}}
  {{- if eq $d.kind "SLO" -}}
    {{- $name := $d.metadata.name -}}
    {{- $spec := $d.spec -}}
    {{- $where := printf "openslo SLO %q" $name -}}
    {{- if not (regexMatch "^[a-z0-9]([-a-z0-9_]*[a-z0-9])?$" $name) }}{{ fail (printf "%s: metadata.name must be lower-case letters, digits, - and _" $where) }}{{ end -}}
    {{- if ne ($spec.budgetingMethod | default "Occurrences") "Occurrences" }}{{ fail (printf "%s: budgetingMethod %s is not supported (Occurrences only)" $where $spec.budgetingMethod) }}{{ end -}}
    {{- if ne (len $spec.objectives) 1 }}{{ fail (printf "%s: exactly one objective is supported" $where) }}{{ end -}}
    {{- $o := index $spec.objectives 0 -}}
    {{- $objective := 0.0 -}}
    {{- if hasKey $o "targetPercent" }}{{ $objective = float64 $o.targetPercent }}{{ else if hasKey $o "target" }}{{ $objective = mulf (float64 $o.target) 100 }}{{ else }}{{ fail (printf "%s: the objective needs target or targetPercent" $where) }}{{ end -}}
    {{- with $spec.timeWindow -}}
      {{- $tw := index . 0 -}}
      {{- $want := list (printf "%dd" (int $.Values.sloPeriodDays)) -}}
      {{- if eq (mod (int $.Values.sloPeriodDays) 7) 0 }}{{ $want = append $want (printf "%dw" (div (int $.Values.sloPeriodDays) 7)) }}{{ end -}}
      {{- if or (not $tw.isRolling) (not (has $tw.duration $want)) }}{{ fail (printf "%s: timeWindow must be rolling and %s, the chart's sloPeriodDays (got %v, rolling %v)" $where (join " or " $want) $tw.duration $tw.isRolling) }}{{ end -}}
    {{- end -}}
    {{- $ind := dict -}}
    {{- if $spec.indicator }}{{ $ind = $spec.indicator.spec }}{{ else if $spec.indicatorRef }}{{ $ind = index $slis $spec.indicatorRef | default dict }}{{ if not $ind }}{{ fail (printf "%s: indicatorRef %q has no kind SLI in openslo" $where $spec.indicatorRef) }}{{ end }}{{ else }}{{ fail (printf "%s: needs indicator or indicatorRef" $where) }}{{ end -}}
    {{- $r := $ind.ratioMetric -}}
    {{- if not $r }}{{ fail (printf "%s: only ratioMetric indicators are supported (thresholdMetric has no event counts to burn a budget from)" $where) }}{{ end -}}
    {{- if $r.raw }}{{ fail (printf "%s: ratioMetric.raw is not supported; give good/total or bad/total" $where) }}{{ end -}}
    {{- if not $r.total }}{{ fail (printf "%s: ratioMetric needs total" $where) }}{{ end -}}
    {{- $total := include "slo.openslo.query" (dict "m" $r.total "counter" $r.counter "where" $where) -}}
    {{- $errorQ := "" -}}
    {{- if $r.bad -}}
      {{- $errorQ = include "slo.openslo.query" (dict "m" $r.bad "counter" $r.counter "where" $where) -}}
    {{- else if $r.good -}}
      {{- $errorQ = printf "(%s) - (%s)" $total (include "slo.openslo.query" (dict "m" $r.good "counter" $r.counter "where" $where)) -}}
    {{- else -}}
      {{- fail (printf "%s: ratioMetric needs good or bad" $where) -}}
    {{- end -}}
    {{- $labels := dict -}}
    {{- range $k, $v := ($d.metadata.labels | default dict) -}}
      {{- $_ := set $labels (regexReplaceAll "[^a-zA-Z0-9_]" $k "_") (ternary (join "," $v) (toString $v) (kindIs "slice" $v)) -}}
    {{- end -}}
    {{- $slo := dict "name" $name "objective" $objective "sli" (dict "errorQuery" $errorQ "totalQuery" $total) "labels" $labels -}}
    {{- with $spec.service }}{{ $_ := set $slo "service" . }}{{ end -}}
    {{- with ($spec.description | default ($d.metadata.displayName | default "")) }}{{ $_ := set $slo "description" . }}{{ end -}}
    {{- $out = append $out $slo -}}
  {{- end -}}
{{- end -}}
{{- $seen := dict -}}
{{- range $s := $out }}{{ if hasKey $seen $s.name }}{{ fail (printf "SLO name %q is defined twice (slos and openslo share one namespace)" $s.name) }}{{ end }}{{ $_ := set $seen $s.name true }}{{ end -}}
{{- toYaml $out -}}
{{- end -}}

{{/*
One OpenSLO metricSource as a PromQL expression with $WINDOW in it. Call with dict m (good/bad/total), counter, where.
*/}}
{{- define "slo.openslo.query" -}}
{{- $ms := .m.metricSource | default dict -}}
{{- $type := lower ($ms.type | default "prometheus") -}}
{{- if ne $type "prometheus" }}{{ fail (printf "%s: metricSource type %s is not supported (Prometheus only)" .where $ms.type) }}{{ end -}}
{{- $q := trim (dig "spec" "query" "" $ms) -}}
{{- if not $q }}{{ fail (printf "%s: metricSource.spec.query is empty" .where) }}{{ end -}}
{{- $q = regexReplaceAllLiteral "\\{\\{\\s*\\.window\\s*\\}\\}" $q "$WINDOW" -}}
{{- if not (contains "$WINDOW" $q) -}}
  {{- if not .counter }}{{ fail (printf "%s: query %q has no range placeholder ($WINDOW or {{.window}}); write one, or set counter: true on a plain counter selector" .where $q) }}{{ end -}}
  {{- if not (regexMatch "^[a-zA-Z_:][a-zA-Z0-9_:]*(\\{[^{}]*\\})?$" $q) }}{{ fail (printf "%s: query %q is not a plain metric selector; write the range as $WINDOW yourself" .where $q) }}{{ end -}}
  {{- $q = printf "sum(rate(%s[$WINDOW]))" $q -}}
{{- end -}}
{{- $q -}}
{{- end -}}
