{{/* Short default name ("tei"): resource names are <release>-tei-<model>. */}}
{{- define "tei.name" -}}
{{- default "tei" .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "tei.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 40 | trimSuffix "-" }}
{{- else }}
{{- $name := include "tei.name" . }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 40 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 40 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "tei.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* Pass (dict "ctx" $ "model" "<name>"); without model: release-wide labels. */}}
{{- define "tei.selectorLabels" -}}
app.kubernetes.io/name: {{ include "tei.name" .ctx }}
app.kubernetes.io/instance: {{ .ctx.Release.Name }}
{{- with .model }}
app.kubernetes.io/component: {{ . }}
{{- end }}
{{- end }}

{{- define "tei.labels" -}}
helm.sh/chart: {{ include "tei.chart" .ctx }}
{{ include "tei.selectorLabels" . }}
app.kubernetes.io/version: {{ .ctx.Chart.AppVersion | quote }}
app.kubernetes.io/part-of: text-embeddings-inference
app.kubernetes.io/managed-by: {{ .ctx.Release.Service }}
{{- end }}

{{- define "tei.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "tei.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/* Image tag prefix per accelerator. */}}
{{- define "tei.variant" -}}
{{- $m := dict "cpu" "cpu-" "cpu-arm64" "cpu-arm64-" "turing" "turing-" "ampere" "" "ampere-86" "86-" "ada" "89-" "hopper" "hopper-" "blackwell" "100-" "blackwell-120" "120-" }}
{{- if not (hasKey $m .) }}{{ fail (printf "unknown accelerator %q (cpu, cpu-arm64, turing, ampere, ampere-86, ada, hopper, blackwell, blackwell-120)" .) }}{{ end }}
{{- get $m . }}
{{- end }}

{{/* The models with modelDefaults merged in. Cached per render; returns {"models": [...]}. */}}
{{- define "tei.models" -}}
{{- if not (hasKey . "teiModels") }}
{{- $out := list }}
{{- $seen := dict }}
{{- range .Values.models }}
{{- $m := mergeOverwrite (deepCopy $.Values.modelDefaults) (deepCopy .) }}
{{- if not (regexMatch "^[a-z0-9]([-a-z0-9]{0,20}[a-z0-9])?$" (toString $m.name)) }}{{ fail (printf "models[].name %q: lowercase letters, digits and dashes, at most 22 characters" (toString $m.name)) }}{{ end }}
{{- if hasKey $seen $m.name }}{{ fail (printf "models: duplicate name %q" $m.name) }}{{ end }}
{{- $_ := set $seen $m.name true }}
{{- if not $m.modelId }}{{ fail (printf "models[%s].modelId is required" $m.name) }}{{ end }}
{{- if not (has $m.cache.mode (list "emptyDir" "persistent" "existingClaim")) }}{{ fail (printf "models[%s].cache.mode must be emptyDir, persistent or existingClaim" $m.name) }}{{ end }}
{{- if and $m.autoscaling.enabled $m.autoscaling.keda.enabled }}{{ fail (printf "models[%s].autoscaling: enable the CPU HPA or KEDA, not both" $m.name) }}{{ end }}
{{- $out = append $out $m }}
{{- end }}
{{- $_ := set . "teiModels" (dict "models" $out) }}
{{- end }}
{{- get . "teiModels" | toJson }}
{{- end }}

{{/* CPU count for the thread pools: the CPU limit, else the request, else 1 (rounded up). */}}
{{- define "tei.cpus" -}}
{{- $r := . | default dict }}
{{- $q := toString (dig "limits" "cpu" (dig "requests" "cpu" "1" $r) $r) }}
{{- if hasSuffix "m" $q }}{{ max 1 (div (add (trimSuffix "m" $q | int) 999) 1000) }}
{{- else }}{{ max 1 (ceil ($q | float64)) | int }}
{{- end }}
{{- end }}

{{/* Secret values: given, else stored, else generated. Cached per render. */}}
{{- define "tei.secretData" -}}
{{- if not (hasKey . "teiSecretData") }}
{{- $old := dict -}}
{{- with lookup "v1" "Secret" .Release.Namespace (include "tei.fullname" .) }}{{ $old = .data | default dict }}{{ end -}}
{{- $data := dict -}}
{{- if and .Values.auth.enabled (not .Values.auth.existingSecret) }}
{{- $_ := set $data "api-key" (coalesce .Values.auth.apiKey (get $old "api-key" | b64dec) (printf "tei-%s" (randAlphaNum 40))) }}
{{- end }}
{{- if and .Values.huggingface.token (not .Values.huggingface.existingSecret) }}
{{- $_ := set $data "hf-token" .Values.huggingface.token }}
{{- end }}
{{- $_ := set . "teiSecretData" (toYaml $data) }}
{{- end }}
{{- get . "teiSecretData" }}
{{- end }}
