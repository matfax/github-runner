{{/*
Expand the name of the chart.
*/}}
{{- define "runner-watcher.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "runner-watcher.fullname" -}}
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

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "runner-watcher.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "runner-watcher.labels" -}}
helm.sh/chart: {{ include "runner-watcher.chart" . }}
{{ include "runner-watcher.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "runner-watcher.selectorLabels" -}}
app.kubernetes.io/name: {{ include "runner-watcher.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "runner-watcher.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "runner-watcher.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Image reference from {repository, tag}; a tag starting with "@" is a bare digest.
*/}}
{{- define "runner-watcher.image" -}}
{{- if hasPrefix "@" .tag }}{{ .repository }}{{ .tag }}{{ else }}{{ .repository }}:{{ .tag }}{{ end }}
{{- end }}

{{/*
Cache server name and the URL runners use to reach it
*/}}
{{- define "runner-watcher.cacheName" -}}
{{- printf "%s-cache" (include "runner-watcher.fullname" .) | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "runner-watcher.cacheUrl" -}}
{{- printf "http://%s.%s.svc.%s:%v" (include "runner-watcher.cacheName" .) .Release.Namespace .Values.clusterDomain .Values.cache.service.port }}
{{- end }}
