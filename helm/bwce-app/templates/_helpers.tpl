{{/* Chart name, truncated to the 63-char DNS label limit. */}}
{{- define "bwce-app.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/* Fully qualified app name. */}}
{{- define "bwce-app.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{- define "bwce-app.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "bwce-app.selectorLabels" -}}
app.kubernetes.io/name: {{ include "bwce-app.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "bwce-app.labels" -}}
helm.sh/chart: {{ include "bwce-app.chart" . }}
{{ include "bwce-app.selectorLabels" . }}
app.kubernetes.io/version: {{ (.Values.image.tag | default .Chart.AppVersion) | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: tibco-bwce
{{- end }}

{{- define "bwce-app.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "bwce-app.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/* Name of the Secret holding sensitive app properties, empty if none. */}}
{{- define "bwce-app.secretName" -}}
{{- if .Values.appSecret.existingSecret }}
{{- .Values.appSecret.existingSecret }}
{{- else if .Values.appSecret.data }}
{{- include "bwce-app.fullname" . }}
{{- end }}
{{- end }}

{{/* Profile file name with exactly one .substvar suffix. */}}
{{- define "bwce-app.profileFile" -}}
{{- printf "%s.substvar" (trimSuffix ".substvar" .Values.bwce.profile) }}
{{- end }}
