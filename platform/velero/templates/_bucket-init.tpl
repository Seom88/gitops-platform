{{/*
DEPRECATED alias: the bucket-init script source-of-truth now lives in the
s3-bucket-lib library chart (define "s3-bucket-lib.bucketInitScript").
This wrapper keeps existing renders working: job-bucket-init.yaml still
includes "velero.bucketInitScript", which delegates to the library.
New consumers should include "s3-bucket-lib.bucketInitScript" directly.
*/}}
{{- define "velero.bucketInitScript" -}}
{{ include "s3-bucket-lib.bucketInitScript" . }}
{{- end }}
