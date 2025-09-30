{{- define "hd.labels" -}}
{{- $required := dict "app.kubernetes.io/part-of" "hybrid-deployment" }}
{{- if .Release }}
  {{- $required = mergeOverwrite $required (dict "app.kubernetes.io/app" .Release.Name) }}
{{- else }}
  {{- $required = mergeOverwrite $required (dict "app.kubernetes.io/app" "default-app") }}
{{- end }}
{{- $extra := .labels | default dict }}
{{- $merged := mergeOverwrite (deepCopy $required) (deepCopy $extra) }}
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
