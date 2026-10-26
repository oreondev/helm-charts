{{- define "gab.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "gab.fullname" -}}
{{- if contains .Chart.Name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "gab.labels" -}}
helm.sh/chart: {{ include "gab.chart" . }}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "gab.gatewayName" -}}
{{- .Values.gateway.name | default (include "gab.fullname" .) -}}
{{- end -}}

{{- define "gab.gatewayNamespace" -}}
{{- .Values.gateway.namespace | default .Release.Namespace -}}
{{- end -}}

{{/*
Listener name for a hostname: https-www-example-com, https-wildcard-example-com.
*/}}
{{- define "gab.listenerName" -}}
{{- printf "https-%s" (. | replace "*." "wildcard-" | replace "." "-") | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Namespace of a route. Dict: root, route.
*/}}
{{- define "gab.routeNamespace" -}}
{{- .route.namespace | default .root.Values.routeDefaults.namespace | default .root.Release.Namespace -}}
{{- end -}}

{{/*
Listener TLS block. Dict: tls (listeners.https.tls), certificateRefs (list).
*/}}
{{- define "gab.tls" -}}
{{- $mode := .tls.mode | default "Terminate" }}
mode: {{ $mode }}
{{- if eq $mode "Terminate" }}
certificateRefs:
{{- if .certificateRefs }}
{{- toYaml .certificateRefs | nindent 2 }}
{{- else }} []
{{- end }}
{{- end }}
{{- with .tls.options }}
options:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end -}}

{{/*
Names of the chart's HTTPS listeners that a set of route hostnames can attach to, comma-separated.
Dict: root, hostnames (list; empty = all HTTPS listeners). Empty result = nothing matches.
*/}}
{{- define "gab.httpsListenerNames" -}}
{{- $root := .root -}}
{{- $https := $root.Values.gateway.listeners.https -}}
{{- $names := dict -}}
{{- if $https.enabled -}}
{{- if not $https.hostnames -}}
{{- $_ := set $names "https" true -}}
{{- else -}}
{{- range $entry := $https.hostnames -}}
{{- $lh := $entry -}}
{{- if ne (kindOf $entry) "string" }}{{ $lh = $entry.hostname }}{{ end -}}
{{- $lname := include "gab.listenerName" $lh -}}
{{- if not $.hostnames -}}
{{- $_ := set $names $lname true -}}
{{- else -}}
{{- range $rh := $.hostnames -}}
{{- if eq $lh $rh -}}
{{- $_ := set $names $lname true -}}
{{- else if hasPrefix "*." $lh -}}
{{- $suffix := trimPrefix "*" $lh -}}
{{- if and (hasSuffix $suffix $rh) (ne $rh (trimPrefix "." $suffix)) }}{{ $_ := set $names $lname true }}{{ end -}}
{{- else if hasPrefix "*." $rh -}}
{{- $suffix := trimPrefix "*" $rh -}}
{{- if hasSuffix $suffix $lh }}{{ $_ := set $names $lname true }}{{ end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- keys $names | sortAlpha | join "," -}}
{{- end -}}

{{/*
parentRefs for a route as a YAML list. Dict: root, route.
*/}}
{{- define "gab.parentRefs" -}}
{{- $root := .root -}}
{{- $route := .route -}}
{{- if $route.parentRefs -}}
{{- toYaml $route.parentRefs -}}
{{- else -}}
{{- $base := dict "group" "gateway.networking.k8s.io" "kind" "Gateway" "name" (include "gab.gatewayName" $root) "namespace" (include "gab.gatewayNamespace" $root) -}}
{{- $section := $root.Values.routeDefaults.sectionName -}}
{{- if hasKey $route "sectionName" }}{{ $section = $route.sectionName }}{{ end -}}
{{- if eq $section "https" -}}
{{- $names := include "gab.httpsListenerNames" (dict "root" $root "hostnames" ($route.hostnames | default list)) -}}
{{- if not $names }}{{ fail (printf "route %q: no HTTPS listener of the Gateway matches hostnames %s (set sectionName per route or routeDefaults.sectionName)" $route.name (toJson ($route.hostnames | default list))) }}{{ end -}}
{{- $refs := list -}}
{{- range $n := splitList "," $names }}{{ $refs = append $refs (merge (dict "sectionName" $n) $base) }}{{ end -}}
{{- toYaml $refs -}}
{{- else -}}
{{- if $section }}{{ $_ := set $base "sectionName" $section }}{{ end -}}
{{- toYaml (list $base) -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Effective timeouts for a route (route.timeouts over routeDefaults.timeouts, empty values dropped), as YAML. Dict: root, route.
*/}}
{{- define "gab.routeTimeouts" -}}
{{- $t := dict -}}
{{- $src := mergeOverwrite (deepCopy (.root.Values.routeDefaults.timeouts | default dict)) (deepCopy (.route.timeouts | default dict)) -}}
{{- range $k, $v := $src }}{{ if $v }}{{ $_ := set $t $k $v }}{{ end }}{{ end -}}
{{- toYaml $t -}}
{{- end -}}

{{/*
HTTPRoute rules with defaults filled in: timeouts, and the security headers merged into (or added as) a
ResponseHeaderModifier filter. Redirect rules are left alone. Dict: root, route. Returns a YAML list.
*/}}
{{- define "gab.httpRules" -}}
{{- $root := .root -}}
{{- $route := .route -}}
{{- $timeouts := include "gab.routeTimeouts" . | fromYaml -}}
{{- $secHeaders := $root.Values.routeDefaults.securityHeaders -}}
{{- if hasKey $route "securityHeaders" }}{{ $secHeaders = $route.securityHeaders }}{{ end -}}
{{- $headers := $root.Values.securityHeaders | default dict -}}
{{- $rules := list -}}
{{- range $r := ($route.rules | default list) -}}
{{- $rule := deepCopy $r -}}
{{- $filters := $rule.filters | default list -}}
{{- $isRedirect := false -}}
{{- $hasModifier := false -}}
{{- range $f := $filters -}}
{{- if eq ($f.type | default "") "RequestRedirect" }}{{ $isRedirect = true }}{{ end -}}
{{- if eq ($f.type | default "") "ResponseHeaderModifier" }}{{ $hasModifier = true }}{{ end -}}
{{- end -}}
{{- if and $timeouts (not $isRedirect) (not (hasKey $rule "timeouts")) }}{{ $_ := set $rule "timeouts" $timeouts }}{{ end -}}
{{- if and $secHeaders $headers (not $isRedirect) -}}
{{- if $hasModifier -}}
{{- range $f := $filters -}}
{{- if eq ($f.type | default "") "ResponseHeaderModifier" -}}
{{- $mod := $f.responseHeaderModifier | default dict -}}
{{- $present := dict -}}
{{- range $kind := list "set" "add" }}{{ range $h := (index $mod $kind | default list) }}{{ $_ := set $present (lower $h.name) true }}{{ end }}{{ end -}}
{{- range $h := ($mod.remove | default list) }}{{ $_ := set $present (lower $h) true }}{{ end -}}
{{- $setList := $mod.set | default list -}}
{{- range $k, $v := $headers }}{{ if not (hasKey $present (lower $k)) }}{{ $setList = append $setList (dict "name" $k "value" $v) }}{{ end }}{{ end -}}
{{- $_ := set $mod "set" $setList -}}
{{- $_ := set $f "responseHeaderModifier" $mod -}}
{{- end -}}
{{- end -}}
{{- else -}}
{{- $setList := list -}}
{{- range $k, $v := $headers }}{{ $setList = append $setList (dict "name" $k "value" $v) }}{{ end -}}
{{- $_ := set $rule "filters" (append $filters (dict "type" "ResponseHeaderModifier" "responseHeaderModifier" (dict "set" $setList))) -}}
{{- end -}}
{{- end -}}
{{- $rules = append $rules $rule -}}
{{- end -}}
{{- toYaml $rules -}}
{{- end -}}
