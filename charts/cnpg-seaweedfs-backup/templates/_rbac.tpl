{{/*
cnpg-backup.rbac — least-privilege RBAC for the backup-init Sync hook.
Wrapper (in the consuming app):

  {{- if .Values.backup.enabled }}
  {{- include "cnpg-backup.rbac" $ }}
  {{- end }}

Local wave -1: before the hook (wave 0). The hook's ServiceAccount may only:
- read the static SeaweedFS S3 config Secret (admin creds for provisioning);
- read/create/update (never delete) its own credentials Secret. Update covers
  only the keyless-Secret replace path; usable credentials are never touched.
Reads .Values.backup.secretName and .Values.cnpgBackup.{app,seaweedfs,waves}.
Needs the caller root ($) for .Release.Namespace.
*/}}
{{- define "cnpg-backup.rbac" -}}
{{- $b := .Values.backup -}}
{{- $c := include "cnpg-backup.cfg" $ | fromYaml -}}
{{- $job := printf "%s-backup-init" $c.app -}}
{{- $wave := $c.waves.rbac | default "-1" -}}
{{- $swNs := $c.seaweedfs.namespace | default "seaweedfs" -}}
{{- $swSecret := $c.seaweedfs.secretName | default "seaweedfs-s3-credentials" -}}
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: {{ $job }}
  annotations:
    argocd.argoproj.io/sync-wave: {{ $wave | quote }}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: {{ $job }}
  annotations:
    argocd.argoproj.io/sync-wave: {{ $wave | quote }}
rules:
  # create cannot be name-scoped: resourceNames never match create because the
  # object name does not exist yet at admission, so a name-scoped create rule
  # would always yield 403 "cannot create resource secrets".
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["create"]
  - apiGroups: [""]
    resources: ["secrets"]
    resourceNames: [{{ $b.secretName | quote }}]
    verbs: ["get", "update"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: {{ $job }}
  annotations:
    argocd.argoproj.io/sync-wave: {{ $wave | quote }}
subjects:
  - kind: ServiceAccount
    name: {{ $job }}
    namespace: {{ .Release.Namespace }}
roleRef:
  kind: Role
  name: {{ $job }}
  apiGroup: rbac.authorization.k8s.io
---
# Read-only access to the static SeaweedFS S3 config (lives in seaweedfs ns).
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: {{ $job }}-provisioner
  namespace: {{ $swNs }}
  annotations:
    argocd.argoproj.io/sync-wave: {{ $wave | quote }}
rules:
  - apiGroups: [""]
    resources: ["secrets"]
    resourceNames: [{{ $swSecret | quote }}]
    verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: {{ $job }}-provisioner
  namespace: {{ $swNs }}
  annotations:
    argocd.argoproj.io/sync-wave: {{ $wave | quote }}
subjects:
  - kind: ServiceAccount
    name: {{ $job }}
    namespace: {{ .Release.Namespace }}
roleRef:
  kind: Role
  name: {{ $job }}-provisioner
  apiGroup: rbac.authorization.k8s.io
{{- end -}}
