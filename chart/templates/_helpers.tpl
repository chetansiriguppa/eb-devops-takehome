{{/*
Chart name, truncated to the 63-char DNS label limit.
*/}}
{{- define "demo-service.name" -}}
{{- .Chart.Name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Fully qualified resource name: <release>-<chart>, or just <release> if it already contains the chart name.
*/}}
{{- define "demo-service.fullname" -}}
{{- if contains .Chart.Name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{- define "demo-service.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "demo-service.labels" -}}
helm.sh/chart: {{ include "demo-service.chart" . }}
{{ include "demo-service.selectorLabels" . }}
app.kubernetes.io/version: {{ .Values.config.version | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels are kept minimal and stable: changing them would orphan existing ReplicaSets.
*/}}
{{- define "demo-service.selectorLabels" -}}
app.kubernetes.io/name: {{ include "demo-service.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
