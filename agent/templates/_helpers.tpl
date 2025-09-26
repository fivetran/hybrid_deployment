{{/* ----- Required Labels ----- */}}
{{- define "hd.required.labels" -}}
app.kubernetes.io/app: {{ if .Release }}{{ .Release.Name }}{{ else }}default-app{{ end }}
app.kubernetes.io/part-of: hybrid-deployment
{{- end }}

{{/* ----- Merge Labels ----- */}}
{{- define "hd.labels" -}}
{{- $vals := .Values }}
{{- $defaultLabels := fromYaml (include "hd.required.labels" .) }}
{{- $common := $vals.commonLabels | default dict }}
{{- $extra := .labels | default dict }}
{{- $merged := mergeOverwrite (deepCopy $defaultLabels) (deepCopy $common) (deepCopy $extra) }}
{{- if .name }}
  {{- $merged = mergeOverwrite $merged (dict "app.kubernetes.io/name" .name) }}
{{- end }}
{{- if gt (len $merged) 0 }}
{{- toYaml $merged }}
{{- end }}
{{- end }}

{{/* ----- Merge Annotations ----- */}}
{{- define "hd.annotations" -}}
{{- $vals := .Values }}
{{- $common := $vals.commonAnnotations | default dict }}
{{- $extra := .annotations | default dict }}
{{- $merged := mergeOverwrite (deepCopy $common) (deepCopy $extra) }}
{{- if gt (len $merged) 0 }}
{{- toYaml $merged }}
{{- end }}
{{- end }}

{{/* ----- Generic Metadata ----- */}}
{{- define "hd.metadata" -}}
metadata:
  {{- if .name }}
  name: {{ .name }}
  {{- end }}
  {{- if not .clusterScoped }}
  namespace: {{ if .Release }}{{ .Release.Namespace }}{{ else }}default{{ end }}
  {{- end }}

  {{- /* Labels */}}
  {{- $labels := dict "Values" .Values "labels" (.labels | default dict) "name" .name }}
  {{- $labelsYaml := include "hd.labels" $labels | trim }}
  {{- if $labelsYaml }}
  labels:
{{ $labelsYaml | indent 4 }}
  {{- end }}

  {{- /* Annotations */}}
  {{- if .annotations }}
    {{- $annotations := dict "Values" .Values "annotations" (.annotations | default dict) }}
    {{- $annotationsYaml := include "hd.annotations" $annotations | trim }}
    {{- if $annotationsYaml }}
  annotations:
{{ $annotationsYaml | indent 4 }}
    {{- end }}
  {{- end }}
{{- end }}
