{{/*
Expand the name of the chart.
*/}}
{{- define "docker-dind.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "docker-dind.fullname" -}}
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
{{- define "docker-dind.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "docker-dind.labels" -}}
helm.sh/chart: {{ include "docker-dind.chart" . }}
{{ include "docker-dind.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "docker-dind.selectorLabels" -}}
app.kubernetes.io/name: {{ include "docker-dind.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "docker-dind.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "docker-dind.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Secret holding the server certificate (tls.crt, tls.key, ca.crt)
*/}}
{{- define "docker-dind.tlsSecretName" -}}
{{- .Values.tls.existingSecret | default (printf "%s-tls" (include "docker-dind.fullname" .)) }}
{{- end }}

{{/*
Secret holding the CA bundle client certificates must chain to
*/}}
{{- define "docker-dind.clientCASecretName" -}}
{{- .Values.tls.clientCA.secretName | default (include "docker-dind.tlsSecretName" .) }}
{{- end }}

{{/*
DNS names the server certificate covers, as a YAML list
*/}}
{{- define "docker-dind.dnsNames" -}}
{{- $svc := include "docker-dind.fullname" . -}}
{{- $ns := .Release.Namespace -}}
- {{ printf "%s.%s.svc.%s" $svc $ns .Values.clusterDomain }}
- {{ printf "%s.%s.svc" $svc $ns }}
- {{ printf "%s.%s" $svc $ns }}
- {{ $svc }}
{{- range .Values.tls.certManager.extraDnsNames }}
- {{ . }}
{{- end }}
{{- end }}

{{/*
Validates the TLS settings
*/}}
{{- define "docker-dind.validateTLS" -}}
{{- if and .Values.tls.existingSecret .Values.tls.certManager.enabled }}
{{- fail "tls.existingSecret and tls.certManager.enabled are mutually exclusive" }}
{{- end }}
{{- if and .Values.tls.certManager.enabled (not .Values.tls.certManager.issuerRef.name) }}
{{- fail "tls.certManager.issuerRef.name is required when tls.certManager.enabled is true" }}
{{- end }}
{{- if not (has .Values.isolation (list "process" "hyperv")) }}
{{- fail "isolation must be \"process\" or \"hyperv\"" }}
{{- end }}
{{- end }}
