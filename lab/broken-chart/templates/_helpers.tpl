{{- define "lab.labels" -}}
app.kubernetes.io/part-of: eb-debug-lab
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end }}
