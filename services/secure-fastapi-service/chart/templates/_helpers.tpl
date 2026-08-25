{{- define "service.name" -}}
{{- .Chart.Name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "service.fullname" -}}
{{- printf "%s-%s" .Release.Name (include "service.name" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "service.labels" -}}
app.kubernetes.io/name: {{ include "service.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
forgepath.dev/owner: {{ .Values.workloadMetadata.owner | quote }}
forgepath.dev/system: {{ .Values.workloadMetadata.system | quote }}
forgepath.dev/environment: {{ .Values.workloadMetadata.environment | quote }}
forgepath.dev/data-classification: {{ .Values.workloadMetadata.dataClassification | quote }}
{{- with .Values.workloadMetadata.supportTier }}
forgepath.dev/support-tier: {{ . | quote }}
{{- end }}
{{- end }}
