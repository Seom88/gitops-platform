# s3-bucket-lib

Shared Helm library chart with the reusable S3 bucket-init shell script for
RustFS (tailnet FQDN) backends. Single source-of-truth migrated from
`platform/velero/templates/_bucket-init.tpl`.

- Chart: `apiVersion: v2`, `type: library`, `version: 0.1.0`
- Template: `templates/_bucket-init.tpl`
- Define: `s3-bucket-lib.bucketInitScript`
- Backwards compat: `platform/velero/templates/_bucket-init.tpl` keeps
  `velero.bucketInitScript` as a deprecated alias that delegates to the new
  define, so existing renders keep working.

## Contract

The script expects a dict:

| Key        | Required | Default              | Meaning                                                     |
|------------|----------|----------------------|-------------------------------------------------------------|
| `fqdn`     | yes      | —                    | Tailnet FQDN of the S3 endpoint (SNI must match the LE cert)|
| `region`   | yes      | —                    | S3 region string passed to aws-cli                           |
| `bucket`   | yes      | —                    | Bucket name to head/create                                   |
| `tag`      | no       | `bucket-init`        | Log prefix (pass the Job name)                               |
| `credFile` | no       | `/etc/velero/cloud`  | Path to the mounted credentials file in the Job container    |

Credentials: each consuming Job mounts its **own** Secret. The script only
reads `$CRED_FILE` (parsed as
`aws_access_key_id=...` / `aws_secret_access_key=...` lines). Velero mounts
`cloud-credentials` at `/etc/velero` (so the default just works); monitoring
mounts its own Secret elsewhere and passes `credFile` explicitly.

## Use from monitoring

1. Add the local dependency in `platform/monitoring/Chart.yaml`:

```yaml
dependencies:
  - name: s3-bucket-lib
    version: 0.1.0
    repository: file://../s3-bucket-lib
```

2. Vendor it (commits `charts/s3-bucket-lib-0.1.0.tgz` + `Chart.lock` update):

```bash
helm dependency update ./platform/monitoring
```

ArgoCD resolves `file://` dependencies from the vendored `charts/*.tgz`
(or by running `helm dependency build` before templating), so either commit
the tgz or ensure the pipeline builds dependencies.

3. Add values (example):

```yaml
s3:
  tailnetFqdn: "rustfs.lonk-mirfak.ts.net" # required, no default
  region: us-east-1
  bucket: loki-chunks

bucketInit:
  enabled: true
  backoffLimit: 3
  activeDeadlineSeconds: 600
  ttlSecondsAfterFinished: 86400
  # Each consumer mounts its own Secret; path must match credFile below.
  secretName: loki-bucket-init-credentials
  credFile: /etc/monitoring/cloud
```

4. Add a Job template (example `platform/monitoring/templates/job-bucket-init.yaml`):

```yaml
{{- if .Values.bucketInit.enabled }}
{{- $fqdn := required "s3.tailnetFqdn is required" .Values.s3.tailnetFqdn }}
apiVersion: batch/v1
kind: Job
metadata:
  name: monitoring-bucket-init
  namespace: monitoring
spec:
  backoffLimit: {{ .Values.bucketInit.backoffLimit | default 3 }}
  ttlSecondsAfterFinished: {{ .Values.bucketInit.ttlSecondsAfterFinished | default 86400 }}
  activeDeadlineSeconds: {{ .Values.bucketInit.activeDeadlineSeconds | default 600 }}
  template:
    spec:
      serviceAccountName: default
      restartPolicy: OnFailure
      containers:
        - name: bucket-init
          image: amazon/aws-cli:2.37.4@sha256:fdd8d1fcbea9c371678dee5a40df8b178c7a781b4586605756ee28114c97ead6
          command: ["/bin/sh", "-c"]
          args:
            - |
              {{- include "s3-bucket-lib.bucketInitScript" (dict "fqdn" $fqdn "region" .Values.s3.region "bucket" .Values.s3.bucket "tag" "monitoring-bucket-init" "credFile" .Values.bucketInit.credFile) | nindent 14 }}
          volumeMounts:
            - name: cloud-credentials
              mountPath: /etc/monitoring
              readOnly: true
      volumes:
        - name: cloud-credentials
          secret:
            secretName: {{ required "bucketInit.secretName is required" .Values.bucketInit.secretName }}
            optional: true
            items:
              - key: cloud
                path: cloud
{{- end }}
```

Verify:

```bash
helm lint ./platform/s3-bucket-lib
helm lint ./platform/monitoring
helm template monitoring ./platform/monitoring \
  --set s3.tailnetFqdn=rustfs.lonk-mirfak.ts.net \
  --show-only templates/job-bucket-init.yaml
```
