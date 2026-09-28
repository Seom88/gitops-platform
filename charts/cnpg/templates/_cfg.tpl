{{/*
cnpg.defaults — baseline values. A library chart's own values.yaml is
never merged into the consumer, so every template builds its config through
"cnpg.cfg" (deep-merged defaults + .Values.cnpgBackup).
*/}}
{{- define "cnpg.defaults" -}}
app: ""
cluster: ""
storeName: ""
namespace: ""
image: "amazon/aws-cli:2.37.0@sha256:337494c2047176fe9abcf45a5d1eaf1c2c62cae40953284fb1143b5c6170f065"
imagePullPolicy: IfNotPresent
backoffLimit: 3
ttlSecondsAfterFinished: 600
activeDeadlineSeconds: 600
seaweedfs:
  namespace: seaweedfs
  secretName: seaweedfs-s3-credentials
  s3Port: 8333
  s3Component: s3
waves:
  rbac: "-1"
  hook: "0"
  resources: "1"
{{- end -}}

{{/*
cnpg.cfg — merged config dict (defaults overwritten by the consumer's
.Values.cnpgBackup). Usage inside other cnpg.* templates:

  {{- $c := include "cnpg.cfg" $ | fromYaml -}}
*/}}
{{- define "cnpg.cfg" -}}
{{- mergeOverwrite (include "cnpg.defaults" $ | fromYaml) (.Values.cnpgBackup | default dict) | toYaml -}}
{{- end -}}
