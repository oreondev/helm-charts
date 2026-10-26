{{- define "otel.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "otel.fullname" -}}
{{- if contains .Chart.Name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "otel.labels" -}}
helm.sh/chart: {{ include "otel.chart" . }}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "otel.agentName" -}}
{{- .Values.agent.name | default (printf "%s-agent" .Release.Name) | trunc 52 | trimSuffix "-" -}}
{{- end -}}

{{- define "otel.gatewayName" -}}
{{- .Values.gateway.name | default (printf "%s-gateway" .Release.Name) | trunc 52 | trimSuffix "-" -}}
{{- end -}}

{{- define "otel.instrumentationName" -}}
{{- .Values.instrumentation.name | default .Release.Name -}}
{{- end -}}

{{- define "otel.agentLocalService" -}}
{{- printf "%s-local" (include "otel.agentName" .) -}}
{{- end -}}

{{/*
The app.kubernetes.io/instance label the operator puts on a collector's pods: "<namespace>.<name>" cut to
63 characters the way its naming.Truncate does (namespace shortened first, then the name, then leading and
trailing non-alphanumerics removed). Dict: ns, name.
*/}}
{{- define "otel.instanceLabel" -}}
{{- $ns := .ns -}}
{{- $name := .name -}}
{{- $excess := int (sub (add (len $ns) (len $name) 1) 63) -}}
{{- if gt $excess 0 -}}
{{- if gt (int (len $ns)) $excess -}}
{{- $ns = substr 0 (int (sub (len $ns) $excess)) $ns -}}
{{- $excess = 0 -}}
{{- else -}}
{{- $excess = int (sub $excess (len $ns)) -}}
{{- $ns = "" -}}
{{- end -}}
{{- if gt $excess 0 -}}
{{- $name = substr 0 (int (sub (len $name) $excess)) $name -}}
{{- end -}}
{{- end -}}
{{- $s := printf "%s.%s" $ns $name -}}
{{- $s = regexReplaceAll "[^A-Za-z0-9]+$" $s "" -}}
{{- regexReplaceAll "^[^A-Za-z0-9]+" $s "" -}}
{{- end -}}

{{/* OTLP/gRPC address of the gateway Service the operator creates. */}}
{{- define "otel.gatewayEndpoint" -}}
{{- printf "%s-collector.%s.svc.cluster.local:4317" (include "otel.gatewayName" .) .Release.Namespace -}}
{{- end -}}

{{/* OTLP/HTTP endpoint SDKs should use. */}}
{{- define "otel.instrumentationEndpoint" -}}
{{- if .Values.instrumentation.endpoint -}}
{{- .Values.instrumentation.endpoint -}}
{{- else if and .Values.agent.enabled .Values.agent.receivers.otlp.enabled -}}
{{- printf "http://%s.%s.svc.cluster.local:4318" (include "otel.agentLocalService" .) .Release.Namespace -}}
{{- else -}}
{{- printf "http://%s-collector.%s.svc.cluster.local:4318" (include "otel.gatewayName" .) .Release.Namespace -}}
{{- end -}}
{{- end -}}

{{/* Flat map with snake_cased keys, as YAML. */}}
{{- define "otel.snake" -}}
{{- $out := dict -}}
{{- range $k, $v := . }}{{ $_ := set $out (snakecase $k) $v }}{{ end -}}
{{- toYaml $out -}}
{{- end -}}

{{/* Fail early when a contrib-only exporter is enabled without an explicit image. */}}
{{- define "otel.checkImage" -}}
{{- if not .Values.image -}}
{{- range $n := list "googlecloud" "googlemanagedprometheus" "datadog" "elasticsearch" -}}
{{- if (index $.Values.backends $n).enabled }}{{ fail (printf "backends.%s needs the contrib distribution: set image (e.g. otel/opentelemetry-collector-contrib:0.163.2)" $n) }}{{ end -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/* Signals at least one enabled backend accepts, comma-separated and sorted. All three when no backend is on. */}}
{{- define "otel.signals" -}}
{{- $set := dict -}}
{{- $b := .Values.backends -}}
{{- range $name := list "otlp" "otlphttp" "googlecloud" "datadog" "elasticsearch" "debug" -}}
{{- $cfg := index $b $name -}}
{{- if and $cfg $cfg.enabled }}{{ range $s := ($cfg.signals | default list) }}{{ $_ := set $set $s true }}{{ end }}{{ end -}}
{{- end -}}
{{- if $b.googlemanagedprometheus.enabled }}{{ $_ := set $set "metrics" true }}{{ end -}}
{{- if $b.prometheusremotewrite.enabled }}{{ $_ := set $set "metrics" true }}{{ end -}}
{{- if not $set }}{{ $set = dict "logs" true "metrics" true "traces" true }}{{ end -}}
{{- keys $set | sortAlpha | join "," -}}
{{- end -}}

{{/*
Backend exporters. Returns YAML with keys exporters (name -> config) and bySignal (signal -> [names]).
Call with the root context.
*/}}
{{- define "otel.backendExporters" -}}
{{- $ex := dict -}}
{{- $by := dict "traces" (list) "metrics" (list) "logs" (list) -}}
{{- $b := .Values.backends -}}
{{- $queue := dict "enabled" true "queue_size" 5000 -}}
{{- $retry := dict "enabled" true "initial_interval" "5s" "max_interval" "30s" "max_elapsed_time" "300s" -}}
{{- with $b.otlp }}{{ if .enabled -}}
{{- $cfg := dict "endpoint" (required "backends.otlp.endpoint is required" .endpoint) "compression" (.compression | default "gzip") "sending_queue" $queue "retry_on_failure" $retry -}}
{{- with .headers }}{{ $_ := set $cfg "headers" . }}{{ end -}}
{{- with .tls }}{{ $_ := set $cfg "tls" (include "otel.snake" . | fromYaml) }}{{ end -}}
{{- $_ := set $ex "otlp/backend" $cfg -}}
{{- range .signals }}{{ $_ := set $by . (append (index $by .) "otlp/backend") }}{{ end -}}
{{- end }}{{ end -}}
{{- with $b.otlphttp }}{{ if .enabled -}}
{{- $cfg := dict "endpoint" (required "backends.otlphttp.endpoint is required" .endpoint) "compression" (.compression | default "gzip") "sending_queue" $queue "retry_on_failure" $retry -}}
{{- with .headers }}{{ $_ := set $cfg "headers" . }}{{ end -}}
{{- with .tls }}{{ $_ := set $cfg "tls" (include "otel.snake" . | fromYaml) }}{{ end -}}
{{- $_ := set $ex "otlphttp/backend" $cfg -}}
{{- range .signals }}{{ $_ := set $by . (append (index $by .) "otlphttp/backend") }}{{ end -}}
{{- end }}{{ end -}}
{{- with $b.googlecloud }}{{ if .enabled -}}
{{- $cfg := dict "sending_queue" $queue "retry_on_failure" $retry -}}
{{- with .project }}{{ $_ := set $cfg "project" . }}{{ end -}}
{{- $_ := set $ex "googlecloud" $cfg -}}
{{- range .signals }}{{ $_ := set $by . (append (index $by .) "googlecloud") }}{{ end -}}
{{- end }}{{ end -}}
{{- with $b.googlemanagedprometheus }}{{ if .enabled -}}
{{- $cfg := dict -}}
{{- with .project }}{{ $_ := set $cfg "project" . }}{{ end -}}
{{- $_ := set $ex "googlemanagedprometheus" $cfg -}}
{{- $_ := set $by "metrics" (append $by.metrics "googlemanagedprometheus") -}}
{{- end }}{{ end -}}
{{- with $b.prometheusremotewrite }}{{ if .enabled -}}
{{- $rtc := true -}}
{{- if hasKey . "resourceToTelemetryConversion" }}{{ $rtc = .resourceToTelemetryConversion }}{{ end -}}
{{- $cfg := dict "endpoint" (required "backends.prometheusremotewrite.endpoint is required" .endpoint) "resource_to_telemetry_conversion" (dict "enabled" $rtc) "remote_write_queue" (dict "enabled" true "queue_size" 10000 "num_consumers" 5) -}}
{{- with .headers }}{{ $_ := set $cfg "headers" . }}{{ end -}}
{{- with .tls }}{{ $_ := set $cfg "tls" (include "otel.snake" . | fromYaml) }}{{ end -}}
{{- $_ := set $ex "prometheusremotewrite" $cfg -}}
{{- $_ := set $by "metrics" (append $by.metrics "prometheusremotewrite") -}}
{{- end }}{{ end -}}
{{- with $b.datadog }}{{ if .enabled -}}
{{- $cfg := dict "api" (dict "site" (.site | default "datadoghq.com") "key" (required "backends.datadog.apiKey is required" .apiKey)) -}}
{{- $_ := set $ex "datadog" $cfg -}}
{{- range .signals }}{{ $_ := set $by . (append (index $by .) "datadog") }}{{ end -}}
{{- end }}{{ end -}}
{{- with $b.elasticsearch }}{{ if .enabled -}}
{{- if not .endpoints }}{{ fail "backends.elasticsearch.endpoints is required" }}{{ end -}}
{{- $cfg := dict "endpoints" .endpoints "mapping" (dict "mode" (.mappingMode | default "otel")) "sending_queue" $queue "retry_on_failure" $retry -}}
{{- with .apiKey }}{{ $_ := set $cfg "api_key" . }}{{ end -}}
{{- with .tls }}{{ $_ := set $cfg "tls" (include "otel.snake" . | fromYaml) }}{{ end -}}
{{- $_ := set $ex "elasticsearch" $cfg -}}
{{- range .signals }}{{ $_ := set $by . (append (index $by .) "elasticsearch") }}{{ end -}}
{{- end }}{{ end -}}
{{- with $b.debug }}{{ if .enabled -}}
{{- $_ := set $ex "debug" (dict "verbosity" (.verbosity | default "basic")) -}}
{{- range .signals }}{{ $_ := set $by . (append (index $by .) "debug") }}{{ end -}}
{{- end }}{{ end -}}
{{- if not $ex -}}
{{- $_ := set $ex "debug" (dict "verbosity" "basic") -}}
{{- $by = dict "traces" (list "debug") "metrics" (list "debug") "logs" (list "debug") -}}
{{- end -}}
{{- toYaml (dict "exporters" $ex "bySignal" $by) -}}
{{- end -}}

{{- define "otel.memoryLimiter" -}}
{{- toYaml (dict "check_interval" (.checkInterval | default "1s") "limit_percentage" (int (.limitPercentage | default 80)) "spike_limit_percentage" (int (.spikeLimitPercentage | default 25))) -}}
{{- end -}}

{{- define "otel.batch" -}}
{{- toYaml (dict "timeout" (.timeout | default "5s") "send_batch_size" (int (.sendBatchSize | default 8192)) "send_batch_max_size" (int (.sendBatchMaxSize | default 16384))) -}}
{{- end -}}

{{/* resource processor with cluster name, environment and extra attributes. Root context. */}}
{{- define "otel.resourceProcessor" -}}
{{- $attrs := list (dict "key" "k8s.cluster.name" "value" (required "clusterName is required" .Values.clusterName) "action" "upsert") -}}
{{- with .Values.environment }}{{ $attrs = append $attrs (dict "key" "deployment.environment.name" "value" . "action" "upsert") }}{{ end -}}
{{- range $k, $v := .Values.processing.resourceAttributes }}{{ $attrs = append $attrs (dict "key" $k "value" (toString $v) "action" "upsert") }}{{ end -}}
{{- toYaml (dict "attributes" $attrs) -}}
{{- end -}}

{{/* Telemetry block of the collector service config. Root context. */}}
{{- define "otel.telemetry" -}}
{{- $t := .Values.telemetry -}}
{{- $m := dict "level" ($t.level | default "normal") -}}
{{- if $t.readers -}}
{{- $_ := set $m "readers" (list (dict "pull" (dict "exporter" (dict "prometheus" (dict "host" "0.0.0.0" "port" (int $t.metricsPort)))))) -}}
{{- else -}}
{{- $_ := set $m "address" (printf "0.0.0.0:%d" (int $t.metricsPort)) -}}
{{- end -}}
{{- toYaml (dict "logs" (dict "level" ($t.logLevel | default "info")) "metrics" $m) -}}
{{- end -}}

{{/*
Processing processors (health-check filter, redaction, tail sampling) as a YAML map name -> config. Root context.
*/}}
{{- define "otel.processingProcessors" -}}
{{- $p := dict -}}
{{- $cfg := .Values.processing -}}
{{- if $cfg.dropHealthChecks.enabled -}}
{{- $re := printf "^(%s)$" (join "|" $cfg.dropHealthChecks.paths) -}}
{{- $reQ := printf "^(%s)([?].*)?$" (join "|" $cfg.dropHealthChecks.paths) -}}
{{- $conds := list (printf "attributes[\"url.path\"] != nil and IsMatch(attributes[\"url.path\"], %q)" $re) (printf "attributes[\"http.route\"] != nil and IsMatch(attributes[\"http.route\"], %q)" $re) (printf "attributes[\"http.target\"] != nil and IsMatch(attributes[\"http.target\"], %q)" $reQ) -}}
{{- $_ := set $p "filter/healthchecks" (dict "error_mode" "ignore" "traces" (dict "span" $conds)) -}}
{{- end -}}
{{- if $cfg.redact.enabled -}}
{{- $actions := list -}}
{{- range $cfg.redact.attributes }}{{ $actions = append $actions (dict "key" . "action" "delete") }}{{ end -}}
{{- range $cfg.redact.patterns }}{{ $actions = append $actions (dict "pattern" . "action" "delete") }}{{ end -}}
{{- if $actions }}{{ $_ := set $p "attributes/redact" (dict "actions" $actions) }}{{ end -}}
{{- end -}}
{{- if $cfg.tailSampling.enabled -}}
{{- if not .Values.gateway.enabled }}{{ fail "processing.tailSampling needs gateway.enabled: tail sampling must see whole traces, which only the gateway does" }}{{ end -}}
{{- $ts := $cfg.tailSampling -}}
{{- $policies := list -}}
{{- if $ts.errorsAlways }}{{ $policies = append $policies (dict "name" "errors" "type" "status_code" "status_code" (dict "status_codes" (list "ERROR"))) }}{{ end -}}
{{- if $ts.slowMs }}{{ $policies = append $policies (dict "name" "slow" "type" "latency" "latency" (dict "threshold_ms" (int $ts.slowMs))) }}{{ end -}}
{{- $policies = append $policies (dict "name" "baseline" "type" "probabilistic" "probabilistic" (dict "sampling_percentage" $ts.percentage)) -}}
{{- range $ts.extraPolicies }}{{ $policies = append $policies . }}{{ end -}}
{{- $_ := set $p "tail_sampling" (dict "decision_wait" ($ts.decisionWait | default "10s") "num_traces" (int ($ts.numTraces | default 100000)) "policies" $policies) -}}
{{- end -}}
{{- toYaml $p -}}
{{- end -}}

{{/* Processing processor names for a signal, in order, comma-separated. Dict: signal, procs (map). */}}
{{- define "otel.processingOrder" -}}
{{- $names := list -}}
{{- if eq .signal "traces" -}}
{{- range $n := list "filter/healthchecks" "attributes/redact" "tail_sampling" }}{{ if hasKey $.procs $n }}{{ $names = append $names $n }}{{ end }}{{ end -}}
{{- else if eq .signal "logs" -}}
{{- if hasKey .procs "attributes/redact" }}{{ $names = append $names "attributes/redact" }}{{ end -}}
{{- end -}}
{{- join "," $names -}}
{{- end -}}

{{/* Agent collector config as YAML. Root context. */}}
{{- define "otel.agentConfig" -}}
{{- $root := . -}}
{{- $a := .Values.agent -}}
{{- $gw := .Values.gateway.enabled -}}
{{- $signals := splitList "," (include "otel.signals" .) -}}
{{- $receivers := dict -}}
{{- $processors := dict -}}
{{- $exporters := dict -}}
{{- $extensions := dict "health_check" (dict "endpoint" "0.0.0.0:13133") -}}
{{- $serviceExt := list "health_check" -}}
{{- $pipelines := dict -}}
{{- if $a.receivers.otlp.enabled -}}
{{- $_ := set $receivers "otlp" (dict "protocols" (dict "grpc" (dict "endpoint" "0.0.0.0:4317") "http" (dict "endpoint" "0.0.0.0:4318"))) -}}
{{- end -}}
{{- if and $a.receivers.kubeletstats.enabled (has "metrics" $signals) -}}
{{- $ks := $a.receivers.kubeletstats -}}
{{- $skip := true -}}
{{- if hasKey $ks "insecureSkipVerify" }}{{ $skip = $ks.insecureSkipVerify }}{{ end -}}
{{- $_ := set $receivers "kubeletstats" (dict "collection_interval" ($ks.collectionInterval | default "30s") "auth_type" "serviceAccount" "endpoint" "https://${env:K8S_NODE_IP}:10250" "insecure_skip_verify" $skip "metric_groups" ($ks.metricGroups | default (list "node" "pod" "container" "volume"))) -}}
{{- end -}}
{{- if and $a.receivers.hostmetrics.enabled (has "metrics" $signals) -}}
{{- $scrapers := dict -}}
{{- range $a.receivers.hostmetrics.scrapers }}{{ $_ := set $scrapers . (dict) }}{{ end -}}
{{- if hasKey $scrapers "filesystem" -}}
{{- $_ := set $scrapers "filesystem" (dict "exclude_mount_points" (dict "mount_points" (list "/dev/*" "/proc/*" "/sys/*" "/run/k3s/containerd/*" "/run/containerd/*" "/var/lib/docker/*" "/var/lib/kubelet/*" "/snap/*") "match_type" "regexp") "exclude_fs_types" (dict "fs_types" (list "autofs" "binfmt_misc" "bpf" "cgroup2" "configfs" "debugfs" "devpts" "devtmpfs" "fusectl" "hugetlbfs" "iso9660" "mqueue" "nsfs" "overlay" "proc" "procfs" "pstore" "rpc_pipefs" "securityfs" "selinuxfs" "squashfs" "sysfs" "tracefs") "match_type" "strict")) -}}
{{- end -}}
{{- $_ := set $receivers "hostmetrics" (dict "collection_interval" ($a.receivers.hostmetrics.collectionInterval | default "30s") "root_path" "/hostfs" "scrapers" $scrapers) -}}
{{- end -}}
{{- if and $a.receivers.filelog.enabled (has "logs" $signals) -}}
{{- $fl := $a.receivers.filelog -}}
{{- $exclude := list -}}
{{- if $fl.excludeCollectorLogs -}}
{{- $exclude = append $exclude (printf "/var/log/pods/%s_%s-collector*/*/*.log" $root.Release.Namespace (include "otel.agentName" $root)) -}}
{{- if $gw }}{{ $exclude = append $exclude (printf "/var/log/pods/%s_%s-collector*/*/*.log" $root.Release.Namespace (include "otel.gatewayName" $root)) }}{{ end -}}
{{- end -}}
{{- range $fl.excludeNamespaces }}{{ $exclude = append $exclude (printf "/var/log/pods/%s_*/*/*.log" .) }}{{ end -}}
{{- $cfg := dict "include" (list "/var/log/pods/*/*/*.log") "exclude" $exclude "include_file_path" true "include_file_name" false "start_at" ($fl.startAt | default "end") "retry_on_failure" (dict "enabled" true) "operators" (list (dict "id" "container-parser" "type" "container")) -}}
{{- if $fl.checkpoint -}}
{{- $_ := set $cfg "storage" "file_storage/filelog" -}}
{{- $_ := set $extensions "file_storage/filelog" (dict "directory" "/var/lib/otelcol/filelog" "create_directory" true) -}}
{{- $serviceExt = append $serviceExt "file_storage/filelog" -}}
{{- end -}}
{{- $_ := set $receivers "filelog" $cfg -}}
{{- end -}}
{{- /* processors */ -}}
{{- $_ := set $processors "memory_limiter" (include "otel.memoryLimiter" $a.memoryLimiter | fromYaml) -}}
{{- $labels := list -}}
{{- range $a.k8sattributes.extractLabels }}{{ $labels = append $labels (dict "tag_name" .tagName "key" .key "from" (.from | default "pod")) }}{{ end -}}
{{- $annotations := list -}}
{{- range $a.k8sattributes.extractAnnotations }}{{ $annotations = append $annotations (dict "tag_name" .tagName "key" .key "from" (.from | default "pod")) }}{{ end -}}
{{- $extract := dict "metadata" $a.k8sattributes.extractMetadata -}}
{{- if $labels }}{{ $_ := set $extract "labels" $labels }}{{ end -}}
{{- if $annotations }}{{ $_ := set $extract "annotations" $annotations }}{{ end -}}
{{- $_ := set $processors "k8sattributes" (dict "auth_type" "serviceAccount" "passthrough" false "filter" (dict "node_from_env_var" "K8S_NODE_NAME") "extract" $extract "pod_association" (list (dict "sources" (list (dict "from" "resource_attribute" "name" "k8s.pod.ip"))) (dict "sources" (list (dict "from" "resource_attribute" "name" "k8s.pod.uid"))) (dict "sources" (list (dict "from" "connection"))))) -}}
{{- $_ := set $processors "resourcedetection" (dict "detectors" ($a.resourceDetectors | default (list "env")) "timeout" "5s" "override" false) -}}
{{- $_ := set $processors "resource/node" (dict "attributes" (list (dict "key" "k8s.node.name" "value" "${env:K8S_NODE_NAME}" "action" "insert") (dict "key" "host.name" "value" "${env:K8S_NODE_NAME}" "action" "insert"))) -}}
{{- $_ := set $processors "resource" (include "otel.resourceProcessor" $root | fromYaml) -}}
{{- $_ := set $processors "batch" (include "otel.batch" $a.batch | fromYaml) -}}
{{- if not $gw -}}
{{- range $k, $v := (include "otel.processingProcessors" $root | fromYaml) }}{{ $_ := set $processors $k $v }}{{ end -}}
{{- end -}}
{{- /* exporters */ -}}
{{- $by := dict -}}
{{- if $gw -}}
{{- $_ := set $exporters "otlp/gateway" (dict "endpoint" (include "otel.gatewayEndpoint" $root) "tls" (dict "insecure" true) "sending_queue" (dict "enabled" true "queue_size" 5000) "retry_on_failure" (dict "enabled" true "initial_interval" "5s" "max_interval" "30s" "max_elapsed_time" "300s")) -}}
{{- $by = dict "traces" (list "otlp/gateway") "metrics" (list "otlp/gateway") "logs" (list "otlp/gateway") -}}
{{- if .Values.processing.tailSampling.enabled -}}
{{- $_ := set $exporters "loadbalancing/gateway" (dict "routing_key" "traceID" "protocol" (dict "otlp" (dict "tls" (dict "insecure" true) "timeout" "10s" "sending_queue" (dict "enabled" true "queue_size" 5000) "retry_on_failure" (dict "enabled" true))) "resolver" (dict "k8s" (dict "service" (printf "%s-collector-headless.%s" (include "otel.gatewayName" $root) $root.Release.Namespace) "ports" (list 4317)))) -}}
{{- $_ := set $by "traces" (list "loadbalancing/gateway") -}}
{{- end -}}
{{- else -}}
{{- $be := include "otel.backendExporters" $root | fromYaml -}}
{{- $exporters = $be.exporters -}}
{{- $by = $be.bySignal -}}
{{- end -}}
{{- /* pipelines */ -}}
{{- range $s := $signals -}}
{{- $recv := list -}}
{{- if hasKey $receivers "otlp" }}{{ $recv = append $recv "otlp" }}{{ end -}}
{{- if eq $s "metrics" }}{{ range $n := list "kubeletstats" "hostmetrics" }}{{ if hasKey $receivers $n }}{{ $recv = append $recv $n }}{{ end }}{{ end }}{{ end -}}
{{- if and (eq $s "logs") (hasKey $receivers "filelog") }}{{ $recv = append $recv "filelog" }}{{ end -}}
{{- $exps := index $by $s | default list -}}
{{- if and $recv $exps -}}
{{- $procs := list "memory_limiter" "k8sattributes" "resourcedetection" "resource/node" "resource" -}}
{{- range $n := splitList "," (include "otel.processingOrder" (dict "signal" $s "procs" $processors)) }}{{ if $n }}{{ $procs = append $procs $n }}{{ end }}{{ end -}}
{{- $procs = append $procs "batch" -}}
{{- $_ := set $pipelines $s (dict "receivers" $recv "processors" $procs "exporters" $exps) -}}
{{- end -}}
{{- end -}}
{{- $config := dict "receivers" $receivers "processors" $processors "exporters" $exporters "extensions" $extensions "service" (dict "extensions" $serviceExt "telemetry" (include "otel.telemetry" $root | fromYaml) "pipelines" $pipelines) -}}
{{- toYaml (mergeOverwrite $config (deepCopy ($a.extraConfig | default dict))) -}}
{{- end -}}

{{/* Gateway collector config as YAML. Root context. */}}
{{- define "otel.gatewayConfig" -}}
{{- $root := . -}}
{{- $g := .Values.gateway -}}
{{- $signals := splitList "," (include "otel.signals" .) -}}
{{- $receivers := dict "otlp" (dict "protocols" (dict "grpc" (dict "endpoint" "0.0.0.0:4317") "http" (dict "endpoint" "0.0.0.0:4318"))) -}}
{{- $processors := dict "memory_limiter" (include "otel.memoryLimiter" $g.memoryLimiter | fromYaml) "resource" (include "otel.resourceProcessor" $root | fromYaml) "batch" (include "otel.batch" $g.batch | fromYaml) -}}
{{- range $k, $v := (include "otel.processingProcessors" $root | fromYaml) }}{{ $_ := set $processors $k $v }}{{ end -}}
{{- $be := include "otel.backendExporters" $root | fromYaml -}}
{{- $pipelines := dict -}}
{{- range $s := $signals -}}
{{- $exps := index $be.bySignal $s | default list -}}
{{- if $exps -}}
{{- $procs := list "memory_limiter" -}}
{{- range $n := splitList "," (include "otel.processingOrder" (dict "signal" $s "procs" $processors)) }}{{ if $n }}{{ $procs = append $procs $n }}{{ end }}{{ end -}}
{{- $procs = concat $procs (list "resource" "batch") -}}
{{- $_ := set $pipelines $s (dict "receivers" (list "otlp") "processors" $procs "exporters" $exps) -}}
{{- end -}}
{{- end -}}
{{- $config := dict "receivers" $receivers "processors" $processors "exporters" $be.exporters "extensions" (dict "health_check" (dict "endpoint" "0.0.0.0:13133")) "service" (dict "extensions" (list "health_check") "telemetry" (include "otel.telemetry" $root | fromYaml) "pipelines" $pipelines) -}}
{{- toYaml (mergeOverwrite $config (deepCopy ($g.extraConfig | default dict))) -}}
{{- end -}}

{{/*
"Any of these counters is increasing", one term per metric joined with "or".
A single {__name__=~"a|b"} selector cannot be used: rate() drops the metric
name, so two counters with the same labels (refused spans and refused log
records on one receiver) collide and the whole rule fails to evaluate.
Each metric still matches with and without the _total suffix, since only one
spelling exists per collector.
dict: metrics (list), by (string), selector (string), window (string)
*/}}
{{- define "otel.anyIncreasing" -}}
{{- $terms := list }}
{{- range .metrics }}
{{- $terms = append $terms (printf "sum by (%s) (rate({__name__=~\"%s(_total)?\", %s}[%s])) > 0" $.by . $.selector $.window) }}
{{- end }}
{{- join "\nor\n" $terms }}
{{- end }}
