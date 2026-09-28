{{/*
cnpg.cluster — shared CloudNativePG Cluster.
Wrapper (in the consuming app):

  {{ include "cnpg.cluster" $ }}

Reads .Values.backup.enabled, .Values.cnpgBackup.{app,cluster,storeName,waves}
and .Values.cnpg.{instances,imageName,storage,database,owner,postgresql}.
Cluster name is always cnpgBackup.cluster (single source); database/owner come
from .Values.cnpg. The WAL-archiver plugin references the same store name the
ObjectStore uses (<app>-backup-store unless storeName is overridden).
Sync wave defaults to waves.resources so the Cluster applies alongside the
ObjectStore/ScheduledBackup.
*/}}
{{- define "cnpg.cluster" -}}
{{- $b := .Values.backup -}}
{{- $c := include "cnpg.cfg" $ | fromYaml -}}
{{- $n := .Values.cnpg -}}
{{- $store := $c.storeName | default (printf "%s-backup-store" $c.app) -}}
{{- $wave := $c.waves.resources | default "1" -}}
---
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: {{ $c.cluster }}
  annotations:
    argocd.argoproj.io/sync-wave: {{ $wave | quote }}
spec:
  monitoring:
    enablePodMonitor: true
  instances: {{ $n.instances }}
  imageName: {{ $n.imageName }}
{{- if $b.enabled }}
  # WAL archiving via the plugin-barman-cloud CNPG-I plugin (ObjectStore
  # {{ $store }}, see cnpg.store). No legacy .spec.backup section:
  # retention lives on the ObjectStore (.spec.retentionPolicy).
  plugins:
    - name: barman-cloud.cloudnative-pg.io
      enabled: true
      isWALArchiver: true
      parameters:
        barmanObjectName: {{ $store }}
{{- end }}
{{- with $n.postgresql }}
  postgresql:
{{ . | toYaml | nindent 4 }}
{{- end }}

  bootstrap:
    initdb:
      database: {{ $n.database }}
      owner: {{ $n.owner }}

  storage:
{{- if $n.storage.class }}
    storageClass: {{ $n.storage.class }}
{{- end }}
    size: {{ $n.storage.size }}
{{- end -}}
