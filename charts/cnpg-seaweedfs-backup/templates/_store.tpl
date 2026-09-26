{{/*
cnpg-backup.store — ObjectStore + ScheduledBackup (plugin-barman-cloud).
Wrapper (in the consuming app):

  {{- if .Values.backup.enabled }}
  {{- include "cnpg-backup.store" $ }}
  {{- end }}

Reads .Values.backup.{bucket,endpoint,secretName,retentionPolicy,schedule}
and .Values.cnpgBackup.{app,cluster,storeName,waves}.
*/}}
{{- define "cnpg-backup.store" -}}
{{- $b := .Values.backup -}}
{{- $c := include "cnpg-backup.cfg" $ | fromYaml -}}
{{- $store := $c.storeName | default (printf "%s-backup-store" $c.app) -}}
# CloudNativePG Barman backup store (plugin-barman-cloud API:
# barmancloud.cnpg.io/v1 ObjectStore, declarative backups with method: plugin).
# Local wave 1: after the backup-init hook (wave 0).
---
apiVersion: barmancloud.cnpg.io/v1
kind: ObjectStore
metadata:
  name: {{ $store }}
  annotations:
    argocd.argoproj.io/sync-wave: {{ $c.waves.resources | default "1" | quote }}
spec:
  configuration:
    destinationPath: s3://{{ $b.bucket }}/
    endpointURL: {{ $b.endpoint }}
    s3Credentials:
      accessKeyId:
        name: {{ $b.secretName }}
        key: ACCESS_KEY_ID
      secretAccessKey:
        name: {{ $b.secretName }}
        key: SECRET_ACCESS_KEY
  # Recovery-window retention; see the consuming app's values.yaml for the policy rationale.
  retentionPolicy: {{ $b.retentionPolicy | quote }}
---
apiVersion: postgresql.cnpg.io/v1
kind: ScheduledBackup
metadata:
  name: {{ $c.cluster }}-daily
  annotations:
    argocd.argoproj.io/sync-wave: {{ $c.waves.resources | default "1" | quote }}
spec:
  cluster:
    name: {{ $c.cluster }}
  schedule: {{ $b.schedule | quote }}
  method: plugin
  pluginConfiguration:
    name: barman-cloud.cloudnative-pg.io
{{- end -}}
