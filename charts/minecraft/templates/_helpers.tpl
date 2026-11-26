{{- define "minecraft.labels" -}}
app.kubernetes.io/name: minecraft
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "minecraft.selector" -}}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/* Env for the server container: the modpack, mods and RCON wiring derived from values. */}}
{{- define "minecraft.serverEnv" -}}
- name: EULA
  value: "TRUE"
- name: MEMORY
  value: {{ .Values.memory | quote }}
- name: TZ
  value: Pacific/Auckland
{{- with .Values.curseforge.manifest }}
- name: TYPE
  value: AUTO_CURSEFORGE
- name: CF_MODPACK_MANIFEST
  value: /modpack/manifest.json
# Required alongside a local manifest; only names the install.
- name: CF_SLUG
  value: {{ $.Release.Name | quote }}
{{- end }}
{{- with .Values.curseforge.excludeMods }}
- name: CF_EXCLUDE_MODS
  value: {{ join "," . | quote }}
{{- end }}
{{- with .Values.mods }}
- name: MODS
  value: {{ join "\n" . | quote }}
{{- end }}
{{- if .Values.rconSecret }}
- name: RCON_PASSWORD_FILE
  value: /run/secrets/rcon/password
{{- end }}
{{- range $k, $v := .Values.env }}
- name: {{ $k }}
  value: {{ $v | quote }}
{{- end }}
{{- end }}
