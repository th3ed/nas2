{{/*
Common labels for all resources in this chart.
Usage: {{ include "news.commonLabels" . | nindent 4 }}
*/}}
{{- define "news.commonLabels" -}}
app.kubernetes.io/name: news
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: news
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Per-component labels — pass component name via dict.
Usage: {{ include "news.componentLabels" (dict "component" "postgres" "ctx" .) | nindent 4 }}
*/}}
{{- define "news.componentLabels" -}}
{{ include "news.commonLabels" .ctx }}
app.kubernetes.io/component: {{ .component }}
{{- end }}

{{/*
Per-component selector labels (subset of component labels suitable for matchLabels).
Usage: {{ include "news.selectorLabels" (dict "component" "postgres" "ctx" .) | nindent 4 }}
*/}}
{{- define "news.selectorLabels" -}}
app.kubernetes.io/name: news
app.kubernetes.io/instance: {{ .ctx.Release.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end }}

{{/*
Standard node-pinning block (the cross-node DNS gotcha keeps everything on one node).
Usage: {{ include "news.nodeSelector" . | nindent 6 }}
*/}}
{{- define "news.nodeSelector" -}}
{{- with .Values.nodeSelector }}
nodeSelector:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end }}
