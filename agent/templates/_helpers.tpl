{{- define "hd.required.labels" -}}
app.kubernetes.io/app: {{ if .Release }}{{ .Release.Name }}{{ else }}default-app{{ end }}
app.kubernetes.io/part-of: hybrid-deployment
{{- end }}

{{- define "hd.labels" -}}
{{- $vals := .Values }}
{{- $defaultLabels := fromYaml (include "hd.required.labels" .) }}
{{- $extra := .labels | default dict }}
{{- $merged := mergeOverwrite (deepCopy $defaultLabels) (deepCopy $extra) }}
{{- if .name }}
  {{- $merged = mergeOverwrite $merged (dict "app.kubernetes.io/name" .name) }}
{{- end }}
{{- if gt (len $merged) 0 }}
{{- toYaml $merged }}
{{- end }}
{{- end }}

{{- define "hd.annotations" -}}
{{- $extra := .annotations | default dict }}
{{- if gt (len $extra) 0 }}
{{- toYaml $extra }}
{{- end }}
{{- end }}
