{{- define "amr.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "amr.labels" -}}
helm.sh/chart: {{ include "amr.chart" . }}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{/*
Render a list of matchers. Each item is a map {name, value, matchType} (matchType defaults to "=")
or a string "name=value", "name!=value", "name=~value", "name!~value".
*/}}
{{- define "amr.matchers" -}}
{{- range . }}
{{- if eq (kindOf .) "string" }}
{{- $op := regexFind "(=~|!~|!=|=)" . }}
{{- $parts := regexSplit "(=~|!~|!=|=)" . 2 }}
- name: {{ index $parts 0 | trim | quote }}
  value: {{ index $parts 1 | trim | trimAll "\"" | quote }}
  matchType: {{ $op | quote }}
{{- else }}
- name: {{ .name | quote }}
  value: {{ .value | toString | quote }}
  matchType: {{ .matchType | default "=" | quote }}
{{- end }}
{{- end }}
{{- end -}}

{{/*
Matcher that selects a set of severity values. Pass dict label, values.
*/}}
{{- define "amr.severityMatcher" -}}
- name: {{ .label | quote }}
  value: {{ join "|" .values | quote }}
  matchType: {{ if gt (len .values) 1 }}"=~"{{ else }}"="{{ end }}
{{- end -}}

{{/*
toYaml that quotes bare matchType operators ("=" is a special token for some YAML parsers).
*/}}
{{- define "amr.safeYaml" -}}
{{- regexReplaceAll "(?m)^(\\s*-?\\s*matchType: )(=~|!~|!=|=)\\s*$" (toYaml .) "${1}\"${2}\"" -}}
{{- end -}}

{{/*
Normalise muteTimeIntervals entries into the AlertmanagerConfig CRD shape: daysOfMonth as {start, end}
objects (native "24:26" / "24" / 24 accepted), times with startTime/endTime (native start_time/end_time accepted).
Call with the list; returns a YAML list.
*/}}
{{- define "amr.normalizeIntervals" -}}
{{- $out := list -}}
{{- range $mti := . -}}
{{- $m := deepCopy $mti -}}
{{- $tis := list -}}
{{- range $ti := ($m.timeIntervals | default list) -}}
{{- $t := deepCopy $ti -}}
{{- if hasKey $t "daysOfMonth" -}}
{{- $days := list -}}
{{- range $d := $t.daysOfMonth -}}
{{- if eq (kindOf $d) "map" -}}
{{- $days = append $days $d -}}
{{- else -}}
{{- $parts := splitList ":" (toString $d) -}}
{{- $start := int (index $parts 0) -}}
{{- $end := $start -}}
{{- if gt (len $parts) 1 }}{{ $end = int (index $parts 1) }}{{ end -}}
{{- $days = append $days (dict "start" $start "end" $end) -}}
{{- end -}}
{{- end -}}
{{- $_ := set $t "daysOfMonth" $days -}}
{{- end -}}
{{- if hasKey $t "times" -}}
{{- $times := list -}}
{{- range $tr := $t.times -}}
{{- $times = append $times (dict "startTime" ($tr.startTime | default $tr.start_time) "endTime" ($tr.endTime | default $tr.end_time)) -}}
{{- end -}}
{{- $_ := set $t "times" $times -}}
{{- end -}}
{{- $tis = append $tis $t -}}
{{- end -}}
{{- $_ := set $m "timeIntervals" $tis -}}
{{- $out = append $out $m -}}
{{- end -}}
{{- toYaml $out -}}
{{- end -}}

{{/*
Fail unless the receiver name exists (or is the null receiver / empty).
*/}}
{{- define "amr.checkReceiver" -}}
{{- $name := .name }}
{{- if and $name (ne $name .root.Values.nullReceiver) (not (hasKey .root.Values.receivers $name)) }}
{{- fail (printf "receiver %q (used by %s) is not defined under receivers" $name .where) }}
{{- end }}
{{- end -}}
