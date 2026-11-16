{{- define "hd.labels" -}}
{{- $required := dict "app.kubernetes.io/part-of" "hybrid-deployment" }}
{{- if .Release }}
  {{- $required = mergeOverwrite $required (dict "app.kubernetes.io/app" .Release.Name) }}
{{- else }}
  {{- $required = mergeOverwrite $required (dict "app.kubernetes.io/app" "default-app") }}
{{- end }}
{{- $extra := dict }}
{{- if .Values }}
  {{- $extra = .Values.labels | default dict }}
{{- else if .labels }}
  {{- $extra = .labels }}
{{- end }}
{{- $merged := mergeOverwrite (deepCopy $required) (deepCopy $extra) }}
{{- if .name }}
  {{- $merged = mergeOverwrite $merged (dict "app.kubernetes.io/name" .name) }}
{{- end }}
{{- if gt (len $merged) 0 }}
{{- toYaml $merged }}
{{- end }}
{{- end }}

{{- define "hd.selectorLabels" -}}
{{- toYaml (dict "app.kubernetes.io/part-of" "hybrid-deployment" "app.kubernetes.io/app" .Release.Name) }}
{{- end }}

{{- define "hd.annotations" -}}
{{- $extra := .annotations | default dict }}
{{- if gt (len $extra) 0 }}
{{- toYaml $extra }}
{{- end }}
{{- end }}

{{- define "hd.agentRegistryAuthEnabled" -}}
{{- if eq (.Values.config.image_registry_agent_auth | default "NONE") "CUSTOM_USERNAMEPASSWORD" }}true{{ end }}
{{- end }}

{{- define "hd.agentImagePullSecretName" -}}
{{- printf "%s-agent-regcred" .Release.Name }}
{{- end }}

{{- define "hd.agentDockerConfigJson" -}}
{{- with .Values.config }}
{{- $registry := required "config.image_registry_agent is required when config.image_registry_agent_auth is CUSTOM_USERNAMEPASSWORD" .image_registry_agent }}
{{- $username := required "config.image_registry_auth_agent_username is required when config.image_registry_agent_auth is CUSTOM_USERNAMEPASSWORD" .image_registry_auth_agent_username }}
{{- $password := required "config.image_registry_auth_agent_password is required when config.image_registry_agent_auth is CUSTOM_USERNAMEPASSWORD" .image_registry_auth_agent_password }}
{{- $auth := printf "%s:%s" $username $password | b64enc }}
{{- $entry := dict "username" $username "password" $password "auth" $auth }}
{{- dict "auths" (dict $registry $entry) | toJson }}
{{- end }}
{{- end }}
