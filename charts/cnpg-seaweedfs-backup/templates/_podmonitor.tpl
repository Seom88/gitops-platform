{{/*
cnpg-backup.podmonitor — PodMonitor mirror for the CNPG operator metrics.
Wrapper (in the consuming app):

  {{ include "cnpg-backup.podmonitor" $ }}

The operator auto-creates a PodMonitor named <cluster> without the
`release: <monitorRelease>` label that kube-prometheus-stack requires, so
Prometheus ignores it and zero cnpg_* series exist. This mirror carries the
same selector with the release label. Deliberately named <cluster>-mirror:
same name+namespace as the operator object would collide with it.
Wave annotation is opt-in via cnpgBackup.waves.podmonitor (no default), so
charts without one keep their current behavior.
Reads .Values.cnpgBackup.{app,cluster,namespace,waves,monitorRelease}.
Namespace defaults to the app slug (repo convention namespace == app).
*/}}
{{- define "cnpg-backup.podmonitor" -}}
{{- $c := include "cnpg-backup.cfg" $ | fromYaml -}}
{{- $ns := $c.namespace | default $c.app -}}
{{- $release := $c.monitorRelease | default "monitoring" -}}
---
apiVersion: monitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: {{ $c.cluster }}-mirror
  namespace: {{ $ns }}
{{- if $c.waves.podmonitor }}
  annotations:
    argocd.argoproj.io/sync-wave: {{ $c.waves.podmonitor | quote }}
{{- end }}
  labels:
    release: {{ $release }}
    app.kubernetes.io/name: {{ $c.cluster }}
    app.kubernetes.io/part-of: {{ $ns }}
spec:
  jobLabel: cnpg.io/cluster
  namespaceSelector:
    matchNames:
      - {{ $ns }}
  selector:
    matchLabels:
      cnpg.io/cluster: {{ $c.cluster }}
      cnpg.io/podRole: instance
  podMetricsEndpoints:
    - port: metrics
      scheme: http
      interval: 60s
      scrapeTimeout: 10s
{{- end -}}
