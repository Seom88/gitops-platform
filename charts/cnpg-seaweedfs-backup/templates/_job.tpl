{{/*
cnpg-backup.job — idempotent SeaweedFS IAM identity + bucket bootstrap Job.
Wrapper (in the consuming app):

  {{- if .Values.backup.enabled }}
  {{- include "cnpg-backup.job" $ }}
  {{- end }}

Argo CD Sync hook, local wave 0: after RBAC (wave -1), before the Cluster,
ObjectStore and ScheduledBackup (wave 1).

Behavior (preserved from the proven immich hook):
- waits for the SeaweedFS S3 endpoint;
- reuses the existing credentials Secret untouched (never rotates);
- otherwise provisions a dedicated IAM user + access key via the S3-embedded
  IAM API using the static admin identity (provisioning only), attaches a
  bucket-scoped policy, creates the bucket with the ADMIN credentials, verifies
  with head-bucket plus a canary put/delete under the DEDICATED credentials
  (proves the policy end to end, with retries for transient InternalError),
  and only then persists ONLY the generated pair in the Secret;
  (Bucket creation stays in the admin phase because SeaweedFS 4.47 embedded-IAM
  validation has no CreateBucket action, so PutUserPolicy rejects it with
  MalformedPolicyDocument.)
- self-heals the orphan state (IAM user exists remotely while our
  credentials are lost): revokes all orphaned keys, mints one fresh key,
  persists it, and continues the normal flow. Never rotates usable
  credentials.
Generated credential values only ever exist at runtime — never in Git.

Reads .Values.backup.{endpoint,region,bucket,iamUser,secretName} and
.Values.cnpgBackup.{app,namespace,image,imagePullPolicy,backoffLimit,
ttlSecondsAfterFinished,activeDeadlineSeconds,seaweedfs,waves}.
Needs the caller root ($) for .Release.Namespace (Secret lookup scope).
*/}}
{{- define "cnpg-backup.job" -}}
{{- $b := .Values.backup -}}
{{- $c := include "cnpg-backup.cfg" $ | fromYaml -}}
{{- $app := $c.app -}}
{{- $job := printf "%s-backup-init" $app -}}
{{- $wave := $c.waves.hook | default "0" -}}
{{- $swNs := $c.seaweedfs.namespace | default "seaweedfs" -}}
{{- $swSecret := $c.seaweedfs.secretName | default "seaweedfs-s3-credentials" -}}
apiVersion: batch/v1
kind: Job
metadata:
  name: {{ $job }}
  annotations:
    argocd.argoproj.io/hook: Sync
    argocd.argoproj.io/hook-delete-policy: BeforeHookCreation
    argocd.argoproj.io/sync-wave: {{ $wave | quote }}
    argocd.argoproj.io/sync-options: Prune=false
    argocd.argoproj.io/hook-weight: "-1"
    helm.sh/hook-weight: "-1"
spec:
  backoffLimit: {{ $c.backoffLimit | default 3 }}
  ttlSecondsAfterFinished: {{ $c.ttlSecondsAfterFinished | default 600 }}
  activeDeadlineSeconds: {{ $c.activeDeadlineSeconds | default 600 }}
  template:
    metadata:
      labels:
        app.kubernetes.io/name: {{ $job }}
        app.kubernetes.io/component: backup-init
    spec:
      serviceAccountName: {{ $job }}
      restartPolicy: OnFailure
      dnsPolicy: ClusterFirst
      containers:
        - name: backup-init
          # Digest-pinned (fail-closed Trivy gate); Renovate-tracked (regex manager
          # covers charts/*/templates). Refresh:
          # skopeo inspect docker://amazon/aws-cli:<tag> | jq -r .Digest
          image: {{ $c.image }}
          imagePullPolicy: {{ $c.imagePullPolicy | default "IfNotPresent" }}
          env:
            - name: AWS_EC2_METADATA_DISABLED
              value: "true"
            - name: AWS_S3_ADDRESSING_STYLE
              value: "path"
            - name: BACKUP_ENDPOINT
              value: {{ $b.endpoint | quote }}
            - name: BACKUP_REGION
              value: {{ $b.region | quote }}
            - name: BACKUP_BUCKET
              value: {{ $b.bucket | quote }}
            - name: BACKUP_IAM_USER
              value: {{ $b.iamUser | quote }}
            - name: BACKUP_SECRET_NAME
              value: {{ $b.secretName | quote }}
            - name: POD_NAMESPACE
              valueFrom:
                fieldRef:
                  fieldPath: metadata.namespace
          command: ["/bin/sh", "-c"]
          args:
            - |
              set -eu
              echo "[backup-init] Starting {{ title $app }} DB backup bootstrap (SeaweedFS IAM)..."
              echo "[backup-init] Endpoint: $BACKUP_ENDPOINT  Bucket: $BACKUP_BUCKET  User: $BACKUP_IAM_USER"

              API="https://${KUBERNETES_SERVICE_HOST}:${KUBERNETES_SERVICE_PORT}"
              TOKEN="$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)"
              CACERT=/var/run/secrets/kubernetes.io/serviceaccount/ca.crt
              # k8s_api <METHOD> <path> [body-file] -> prints body, then HTTP code on last line
              k8s_api() {
                if [ $# -ge 3 ]; then
                  curl -sS --cacert "$CACERT" -H "Authorization: Bearer $TOKEN" \
                    -H 'Content-Type: application/json' -X "$1" --data @"$3" \
                    -w '\n%{http_code}' "$API$2"
                else
                  curl -sS --cacert "$CACERT" -H "Authorization: Bearer $TOKEN" \
                    -X "$1" -w '\n%{http_code}' "$API$2"
                fi
              }
              resp_code() { printf '%s' "$1" | tail -n 1; }
              resp_body() { printf '%s' "$1" | sed '$d'; }

              # 1. Wait for the SeaweedFS S3 endpoint (any HTTP status proves it serves;
              #    auth-enabled S3 answers 403 on "/").
              echo "[backup-init] Waiting for S3 at $BACKUP_ENDPOINT (max 300s)..."
              WAIT_SECS=0
              while [ $WAIT_SECS -lt 300 ]; do
                CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$BACKUP_ENDPOINT/" || true)"
                if [ "$CODE" != "000" ]; then
                  echo "[backup-init] S3 is serving (HTTP $CODE)."
                  break
                fi
                sleep 5
                WAIT_SECS=$((WAIT_SECS + 5))
              done
              if [ $WAIT_SECS -ge 300 ]; then
                echo "[backup-init] ERROR: S3 not reachable after 300s."
                exit 1
              fi
              # Ensure aws-cli uses path-style addressing (SeaweedFS S3 requires it)
              aws configure set default.s3.addressing_style path || true

              S3="aws --endpoint-url $BACKUP_ENDPOINT --region $BACKUP_REGION"

              # 2. Reuse path: Secret exists with both keys -> verify, never rotate.
              echo "[backup-init] Checking for existing Secret $POD_NAMESPACE/$BACKUP_SECRET_NAME..."
              RESP="$(k8s_api GET "/api/v1/namespaces/$POD_NAMESPACE/secrets/$BACKUP_SECRET_NAME")"
              CODE="$(resp_code "$RESP")"
              BODY="$(resp_body "$RESP")"
              HAVE_SECRET=false
              if [ "$CODE" = "200" ]; then
                HAVE_SECRET=true
                AK="$(printf '%s' "$BODY" | jq -r '.data.ACCESS_KEY_ID // empty | @base64d')"
                SK="$(printf '%s' "$BODY" | jq -r '.data.SECRET_ACCESS_KEY // empty | @base64d')"
                if [ -n "$AK" ] && [ -n "$SK" ]; then
                  echo "[backup-init] Existing credentials found — verifying head-bucket + canary (no rotation)."
                  export AWS_ACCESS_KEY_ID="$AK" AWS_SECRET_ACCESS_KEY="$SK"
                  if $S3 s3api head-bucket --bucket "$BACKUP_BUCKET"; then
                    echo -n "{{ $job }}-reuse $(date -u +%FT%TZ)" > /tmp/canary-reuse
                    if $S3 s3api put-object --bucket "$BACKUP_BUCKET" --key .backup-init-canary --body /tmp/canary-reuse >/dev/null \
                      && $S3 s3api delete-object --bucket "$BACKUP_BUCKET" --key .backup-init-canary >/dev/null; then
                      rm -f /tmp/canary-reuse
                      echo "[backup-init] DONE — existing credentials verified (read + write)."
                      exit 0
                    fi
                    echo "[backup-init] ERROR: stored credentials passed head-bucket but failed the canary put/delete on $BACKUP_BUCKET."
                    echo "[backup-init] Server-side or policy write failure — refusing to rotate automatically."
                    exit 1
                  fi
                  echo "[backup-init] ERROR: stored credentials failed head-bucket on $BACKUP_BUCKET."
                  echo "[backup-init] Restore Secret $BACKUP_SECRET_NAME from backup, or rotate manually"
                  echo "[backup-init] (delete IAM user $BACKUP_IAM_USER and this Secret, then re-sync)."
                  echo "[backup-init] Refusing to overwrite."
                  exit 1
                fi
                echo "[backup-init] Secret exists but holds no usable keys — continuing to provision path."
              elif [ "$CODE" != "404" ]; then
                echo "[backup-init] ERROR: unexpected Secret lookup status $CODE: $BODY"
                exit 1
              fi

              # 3. Provision path: read the static admin identity (provisioning only).
              echo "[backup-init] Reading admin identity from {{ $swNs }}/{{ $swSecret }}..."
              RESP="$(k8s_api GET "/api/v1/namespaces/{{ $swNs }}/secrets/{{ $swSecret }}")"
              CODE="$(resp_code "$RESP")"
              BODY="$(resp_body "$RESP")"
              if [ "$CODE" != "200" ]; then
                echo "[backup-init] ERROR: cannot read admin Secret (HTTP $CODE): $BODY"
                echo "[backup-init] Hint: check RoleBinding {{ $job }}-provisioner in namespace {{ $swNs }}."
                exit 1
              fi
              CFG="$(printf '%s' "$BODY" | jq -r '.data.seaweedfs_s3_config // empty' | base64 -d)"
              ADMIN_AK="$(printf '%s' "$CFG" | jq -r '[.identities[] | select((.actions // []) | index("Admin")) | .credentials[]] | .[0].accessKey // empty')"
              ADMIN_SK="$(printf '%s' "$CFG" | jq -r '[.identities[] | select((.actions // []) | index("Admin")) | .credentials[]] | .[0].secretKey // empty')"
              if [ -z "$ADMIN_AK" ] || [ -z "$ADMIN_SK" ]; then
                echo "[backup-init] ERROR: no Admin identity found in the static S3 config."
                exit 1
              fi
              export AWS_ACCESS_KEY_ID="$ADMIN_AK" AWS_SECRET_ACCESS_KEY="$ADMIN_SK"

              # 4. Orphan recovery: IAM user exists remotely but we hold no credentials.
              # Live-cluster feedback shows this happens in practice (Secret lost while
              # the dynamic IAM identity persists in the SeaweedFS filer). The manual
              # `weed shell` cleanup route proved flaky, so the hook heals itself
              # instead of CrashLooping for manual intervention.
              ORPHAN=false
              if OUT="$($S3 iam get-user --user-name "$BACKUP_IAM_USER" 2>&1)"; then
                echo "[backup-init] ORPHAN RECOVERY starting: IAM user '$BACKUP_IAM_USER' exists"
                echo "[backup-init] but Secret $POD_NAMESPACE/$BACKUP_SECRET_NAME is missing or empty."
                ORPHAN=true
              elif ! printf '%s' "$OUT" | grep -q 'NoSuchEntity'; then
                echo "[backup-init] ERROR: iam get-user failed unexpectedly: $OUT"
                exit 1
              fi

              # 5. Create the dedicated identity + key, attach a bucket-scoped policy.
              if [ "$ORPHAN" = "true" ]; then
                # With the Secret gone no in-cluster consumer can hold those credentials,
                # so revoking unknown keys is the safe action, not rotation risk.
                echo "[backup-init] ORPHAN RECOVERY: listing access keys of $BACKUP_IAM_USER..."
                KEYS_JSON="$($S3 iam list-access-keys --user-name "$BACKUP_IAM_USER")"
                for KEY_ID in $(printf '%s' "$KEYS_JSON" | jq -r '.AccessKeyMetadata[].AccessKeyId // empty'); do
                  echo "[backup-init] ORPHAN RECOVERY: revoking access key (id prefix: $(printf '%.8s' "$KEY_ID")...)."
                  $S3 iam delete-access-key --user-name "$BACKUP_IAM_USER" --access-key-id "$KEY_ID"
                done
                echo "[backup-init] ORPHAN RECOVERY: orphaned keys revoked — minting one fresh key."
              else
                echo "[backup-init] Creating IAM user $BACKUP_IAM_USER..."
                $S3 iam create-user --user-name "$BACKUP_IAM_USER" >/dev/null
              fi
              CREDS="$($S3 iam create-access-key --user-name "$BACKUP_IAM_USER")"
              NEW_AK="$(printf '%s' "$CREDS" | jq -r '.AccessKey.AccessKeyId // empty')"
              NEW_SK="$(printf '%s' "$CREDS" | jq -r '.AccessKey.SecretAccessKey // empty')"
              if [ -z "$NEW_AK" ] || [ -z "$NEW_SK" ]; then
                echo "[backup-init] ERROR: access-key creation returned no credentials."
                exit 1
              fi
              # Dedicated policy uses only valid SeaweedFS 4.47 embedded-IAM actions
              # (getActions() in weed/s3api/s3api_embedded_iam.go:943-999): CreateBucket
              # and ListMultipartUploadParts are NOT valid and PutUserPolicy rejects them
              # with MalformedPolicyDocument, so bucket creation stays in the admin phase
              # below and multipart uses ListParts/ListMultipartUploads. All actions keep
              # the s3: prefix — unprefixed actions are silently skipped by validation.
              jq -n --arg b "$BACKUP_BUCKET" \
                '{Version: "2012-10-17", Statement: [
                  {Effect: "Allow",
                   Action: ["s3:GetBucketLocation", "s3:ListBucket"],
                   Resource: ["arn:aws:s3:::\($b)"]},
                  {Effect: "Allow",
                   Action: ["s3:GetObject", "s3:PutObject", "s3:DeleteObject",
                             "s3:CreateMultipartUpload", "s3:UploadPart",
                             "s3:CompleteMultipartUpload", "s3:AbortMultipartUpload",
                             "s3:ListParts", "s3:ListMultipartUploads"],
                   Resource: ["arn:aws:s3:::\($b)/*"]}]}' > /tmp/bucket-policy.json
              $S3 iam put-user-policy --user-name "$BACKUP_IAM_USER" \
                --policy-name "$BACKUP_IAM_USER-bucket" \
                --policy-document file:///tmp/bucket-policy.json
              echo "[backup-init] Dedicated identity ready (key id prefix: $(printf '%.8s' "$NEW_AK")...)."

              # Bucket creation with ADMIN credentials (still exported): the dedicated
              # policy cannot grant CreateBucket on SeaweedFS 4.47 embedded IAM.
              echo "[backup-init] Creating bucket $BACKUP_BUCKET (admin credentials)..."
              set +e
              OUT="$($S3 s3api create-bucket --bucket "$BACKUP_BUCKET" 2>&1)"
              RC=$?
              set -e
              echo "$OUT"
              if [ $RC -ne 0 ]; then
                if printf '%s' "$OUT" | grep -qiE 'BucketAlreadyOwnedByYou|BucketAlreadyExists|already exists'; then
                  echo "[backup-init] Bucket already exists — continuing (idempotent)."
                else
                  echo "[backup-init] ERROR: create-bucket failed with exit $RC."
                  exit $RC
                fi
              fi

              # 6. Verification BEFORE persist with the DEDICATED credentials (proves
              # the policy end to end). Persisting first would leave a
              # persisted-but-unverified Secret behind on canary failure, and the
              # next retry would take the reuse path (head-bucket only) and report
              # DONE without ever proving Put — a "fallo con exito".
              export AWS_ACCESS_KEY_ID="$NEW_AK" AWS_SECRET_ACCESS_KEY="$NEW_SK"
              echo "[backup-init] Verifying bucket with head-bucket (dedicated credentials)..."
              $S3 s3api head-bucket --bucket "$BACKUP_BUCKET"
              echo "[backup-init] Write-probe with a canary object (proves Put/Delete for backups)..."
              echo -n "{{ $job }} $(date -u +%FT%TZ)" > /tmp/canary
              PUT_OK=false
              for ATTEMPT in 1 2 3 4 5; do
                if $S3 s3api put-object --bucket "$BACKUP_BUCKET" --key .backup-init-canary --body /tmp/canary >/dev/null 2>/tmp/put-err.log; then
                  PUT_OK=true
                  break
                fi
                echo "[backup-init] Canary put attempt $ATTEMPT/5 failed: $(cat /tmp/put-err.log | tr '\n' ' ' | cut -c1-300)"
                # InternalError is server-side (NOT a policy denial — denials are
                # 403); SeaweedFS IAM policy propagation and filer/volume hiccups
                # are transient, so back off before retrying.
                sleep $((ATTEMPT * 5))
              done
              if [ "$PUT_OK" != "true" ]; then
                echo "[backup-init] ERROR: canary put-object failed after 5 attempts (last: $(cat /tmp/put-err.log | tr '\n' ' ' | cut -c1-300))."
                echo "[backup-init] Hints: kubectl logs -n seaweedfs deploy/seaweedfs-s3 + statefulset filer/volume;"
                echo "[backup-init] repro with admin creds to isolate backend vs IAM: if admin put also 500s, the backend (filer/volume) is down;"
                echo "[backup-init] if only the dedicated key 500s, check 'weed shell -> s3.configure' policy propagation."
                echo "[backup-init] Nothing persisted — next re-sync re-runs orphan recovery (revokes key prefix $(printf '%.8s' "$NEW_AK")...) and mints fresh."
                exit 1
              fi
              $S3 s3api delete-object --bucket "$BACKUP_BUCKET" --key .backup-init-canary >/dev/null

              # 7. Persist ONLY the generated pair — never overwrite usable credentials.
              # Reached only after the dedicated pair proved read + write above.
              echo "[backup-init] Verification passed — persisting credentials in Secret $POD_NAMESPACE/$BACKUP_SECRET_NAME..."
              jq -n --arg name "$BACKUP_SECRET_NAME" --arg ak "$NEW_AK" --arg sk "$NEW_SK" \
                '{apiVersion: "v1", kind: "Secret",
                   metadata: {name: $name}, type: "Opaque",
                   stringData: {ACCESS_KEY_ID: $ak, SECRET_ACCESS_KEY: $sk}}' > /tmp/secret-body.json # pragma: allowlist secret (key names, values are runtime-only)
              if [ "$HAVE_SECRET" = "true" ]; then # pragma: allowlist secret (shell flag variable, not a value)
                RV="$(printf '%s' "$BODY" | jq -r '.metadata.resourceVersion // empty')"
                if [ -z "$RV" ]; then
                  echo "[backup-init] ERROR: cannot replace keyless Secret (no resourceVersion)."
                  exit 1
                fi
                jq --arg rv "$RV" '.metadata.resourceVersion = $rv' /tmp/secret-body.json > /tmp/secret-put.json
                RESP="$(k8s_api PUT "/api/v1/namespaces/$POD_NAMESPACE/secrets/$BACKUP_SECRET_NAME" /tmp/secret-put.json)"
              else
                RESP="$(k8s_api POST "/api/v1/namespaces/$POD_NAMESPACE/secrets" /tmp/secret-body.json)"
                CODE="$(resp_code "$RESP")"
                PBODY="$(resp_body "$RESP")"
                if [ "$CODE" = "409" ] || printf '%s' "$PBODY" | grep -qiE 'AlreadyExists|code[^0-9]*409'; then
                  # Race: Secret was created between the initial GET and this POST
                  # (or this is a retry after partial success). Re-GET for a fresh
                  # resourceVersion, then PUT (replace) with the same generated pair.
                  # Safe: this path is only reached when the initial GET was 404 or
                  # keyless, so there are no usable credentials to overwrite.
                  echo "[backup-init] Secret already exists (409 race) — re-reading for replace..."
                  RESP="$(k8s_api GET "/api/v1/namespaces/$POD_NAMESPACE/secrets/$BACKUP_SECRET_NAME")"
                  CODE="$(resp_code "$RESP")"
                  BODY="$(resp_body "$RESP")"
                  if [ "$CODE" != "200" ]; then
                    echo "[backup-init] ERROR: Secret re-read after 409 failed (HTTP $CODE): $BODY"
                    exit 1
                  fi
                  RV="$(printf '%s' "$BODY" | jq -r '.metadata.resourceVersion // empty')"
                  if [ -z "$RV" ]; then
                    echo "[backup-init] ERROR: cannot replace raced Secret (no resourceVersion)."
                    exit 1
                  fi
                  jq --arg rv "$RV" '.metadata.resourceVersion = $rv' /tmp/secret-body.json > /tmp/secret-put.json
                  RESP="$(k8s_api PUT "/api/v1/namespaces/$POD_NAMESPACE/secrets/$BACKUP_SECRET_NAME" /tmp/secret-put.json)"
                fi
              fi
              CODE="$(resp_code "$RESP")"
              if [ "$CODE" != "200" ] && [ "$CODE" != "201" ]; then
                echo "[backup-init] ERROR: Secret persist failed (HTTP $CODE): $(resp_body "$RESP")"
                echo "[backup-init] Manual recovery: copy the generated key (prefix $(printf '%.8s' "$NEW_AK")...)"
                echo "[backup-init] from the hook logs into Secret $BACKUP_SECRET_NAME, or delete IAM user"
                echo "[backup-init] $BACKUP_IAM_USER and re-sync."
                exit 1
              fi
              echo "[backup-init] Credentials persisted in Secret $POD_NAMESPACE/$BACKUP_SECRET_NAME."
              shred -u /tmp/canary /tmp/secret-body.json /tmp/secret-put.json /tmp/bucket-policy.json 2>/dev/null || true
              echo "[backup-init] DONE — bucket $BACKUP_BUCKET ready, dedicated credentials verified."
{{- end -}}
