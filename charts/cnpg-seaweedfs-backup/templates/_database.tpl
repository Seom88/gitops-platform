{{/*
cnpg-backup.database — declarative CNPG Database CR (extensions as superuser).
Wrapper (in the consuming app):

  {{ include "cnpg-backup.database" $ }}

Renders nothing when .Values.cnpg.dbExtensions is empty (e.g. Grafana uses
plain tables, no Database CR needed). Otherwise creates <cluster>-<database>
in the same sync wave as the Cluster (waves.resources) so extensions exist
before the app Deployment starts.
Reads .Values.cnpg.{database,owner,dbExtensions} and
.Values.cnpgBackup.{cluster,waves}.
*/}}
{{- define "cnpg-backup.database" -}}
{{- $n := .Values.cnpg -}}
{{- $c := include "cnpg-backup.cfg" $ | fromYaml -}}
{{- if $n.dbExtensions }}
{{- $wave := $c.waves.resources | default "1" -}}
---
apiVersion: postgresql.cnpg.io/v1
kind: Database
metadata:
  name: {{ $c.cluster }}-{{ $n.database }}
  annotations:
    argocd.argoproj.io/sync-wave: {{ $wave | quote }}
spec:
  name: {{ $n.database }}
  owner: {{ $n.owner }}
  cluster:
    name: {{ $c.cluster }}
  extensions:
{{ $n.dbExtensions | toYaml | nindent 4 }}
{{- end }}
{{- end -}}
