{{/*
Convert a duration like 30m, 2h, 90s or 1d to seconds. Fails on anything else.
*/}}
{{- define "vbs.seconds" -}}
{{- $d := toString . -}}
{{- $n := regexFind "^[0-9]+" $d -}}
{{- $u := trimPrefix $n $d -}}
{{- if or (not $n) (not (has $u (list "s" "m" "h" "d"))) -}}
{{- fail (printf "unsupported duration %q (use s, m, h or d)" $d) -}}
{{- end -}}
{{- $mult := dict "s" 1 "m" 60 "h" 3600 "d" 86400 -}}
{{- mul (int $n) (index $mult $u) -}}
{{- end -}}
