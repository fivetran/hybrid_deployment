{{/* Define required labels to use */}}
{{- define "hd.required.labels" -}}
app.kubernetes.io/app: {{ .Release.Name }}
app.kubernetes.io/part-of: hybrid-deployment
{{- end -}}

{{/* Merge in any custom labels set in values.yaml */}}
{{- define "hd.labels" -}}
{{- $defaultLabels := fromYaml (include "hd.required.labels" .) }}
{{- if .Values.labels }}{{- $customLabels := .Values.labels | default dict }}{{- else -}}{{- $customLabels := dict -}}{{- end -}}
{{- /* Merge default and custom labels */ -}}
{{- $mergedLabels := merge $defaultLabels $customLabels }}
{{- toYaml $mergedLabels }}
{{- end -}}
