{{/*
cnpg-backup.ciliumEgress — Cilium egress from the CNPG instance pods and the
backup-init hook pods to the SeaweedFS S3 data plane, narrowed to the S3 pods
on the S3 port only. Emit inside the app's Cilium gate, e.g.:

  {{- if .Values.backup.enabled }}
  {{- include "cnpg-backup.ciliumEgress" $ | nindent 0 }}
  {{- end }}

Reads .Values.cnpgBackup.{app,cluster,namespace,seaweedfs}.
Namespace defaults to the app slug (repo convention namespace == app).
*/}}
{{- define "cnpg-backup.ciliumEgress" -}}
{{- $c := include "cnpg-backup.cfg" $ | fromYaml -}}
{{- $job := printf "%s-backup-init" $c.app -}}
{{- $swNs := $c.seaweedfs.namespace | default "seaweedfs" -}}
{{- $swComp := $c.seaweedfs.s3Component | default "s3" -}}
{{- $swPort := $c.seaweedfs.s3Port | default 8333 -}}
{{- $ns := $c.namespace | default $c.app -}}
# CNPG backup data plane -> SeaweedFS S3. Scoped to
# the CNPG instance pods (label cnpg.io/cluster set by the operator) and the
# backup-init hook pods; destination narrowed to the S3 pods on the S3 port only.
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: {{ $c.app }}-backup-to-seaweedfs-s3
  namespace: {{ $ns }}
spec:
  endpointSelector:
    matchLabels:
      cnpg.io/cluster: {{ $c.cluster }}
  egress:
    - toEndpoints:
        - matchLabels:
            k8s:io.kubernetes.pod.namespace: {{ $swNs }}
            k8s:app.kubernetes.io/component: {{ $swComp }}
      toPorts:
        - ports:
            - port: {{ $swPort | quote }}
              protocol: TCP
---
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: {{ $job }}-to-seaweedfs-s3
  namespace: {{ $ns }}
spec:
  endpointSelector:
    matchLabels:
      app.kubernetes.io/name: {{ $job }}
  egress:
    - toEndpoints:
        - matchLabels:
            k8s:io.kubernetes.pod.namespace: {{ $swNs }}
            k8s:app.kubernetes.io/component: {{ $swComp }}
      toPorts:
        - ports:
            - port: {{ $swPort | quote }}
              protocol: TCP
{{- end -}}
