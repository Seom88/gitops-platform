{{/*
Reusable S3 bucket-init shell script for RustFS (tailnet FQDN) backends.

Expects a dict:
  fqdn     - tailnet FQDN of the S3 endpoint (SNI must equal the LE-cert FQDN)
  region   - S3 region string passed to aws-cli
  bucket   - bucket name to head/create
  tag      - log prefix (defaults to "bucket-init"; pass the Job name)
  credFile - path to the mounted credentials file inside the Job container
             (defaults to "/etc/velero/cloud" for backwards compatibility
             with the velero chart; each consuming Job mounts its own Secret
             and passes its own path, e.g. monitoring passes
             "/etc/monitoring/cloud").

The script is intentionally backend-agnostic: DNS-via-node-MagicDNS wait,
private-IP egress gate, runtime /etc/hosts pin, idempotent head/create,
and classified error output (TLS/network vs 403 vs 404). Callers only
supply bucket identity; credentials come from the Secret mounted by each
consuming Job (the script only reads $CRED_FILE).
*/}}
{{- define "s3-bucket-lib.bucketInitScript" -}}
{{- $tag := .tag | default "bucket-init" }}
{{- $credFile := .credFile | default "/etc/velero/cloud" }}
set -e
echo "[{{ $tag }}] Starting S3 bucket init..."
CRED_FILE="{{ $credFile }}"
WAIT_SECS=0
WAIT_MAX=60
while [ ! -f "$CRED_FILE" ] && [ $WAIT_SECS -lt $WAIT_MAX ]; do
  echo "[{{ $tag }}] Waiting for credentials file $CRED_FILE ($WAIT_SECS/$WAIT_MAX s)..."
  sleep 5
  WAIT_SECS=$((WAIT_SECS + 5))
done
if [ ! -f "$CRED_FILE" ]; then
  echo "[{{ $tag }}] ERROR: credentials file not found at $CRED_FILE (Secret missing or not mounted?)"
  echo "[{{ $tag }}] Hint: ensure the consumer chart mounted its credentials Secret at the directory containing $CRED_FILE."
  exit 1
fi
# Velero secret format: "[default]\naws_access_key_id=...\naws_secret_access_key=..."
export AWS_ACCESS_KEY_ID="$(grep -E 'aws_access_key_id' "$CRED_FILE" | cut -d'=' -f2 | tr -d '[:space:]')"
export AWS_SECRET_ACCESS_KEY="$(grep -E 'aws_secret_access_key' "$CRED_FILE" | cut -d'=' -f2 | tr -d '[:space:]')"
export AWS_DEFAULT_REGION="{{ .region }}"
export AWS_EC2_METADATA_DISABLED="true"
export AWS_S3_ADDRESSING_STYLE="path"
# Silence only the expected urllib3 warning (--no-verify-ssl is
# intentional); real errors still surface.
export PYTHONWARNINGS='ignore::urllib3.exceptions.InsecureRequestWarning'
# Ensure aws-cli uses path-style addressing (S3 backend requires it)
aws configure set default.s3.addressing_style path || true
aws configure set default.s3.addressing_style path --profile default || true
# Tailnet FQDN resolution via node MagicDNS: pods resolve $S3_FQDN
# through the default CoreDNS forward chain (kube-dns -> node
# /etc/resolv.conf -> tailscaled MagicDNS on the host). No
# in-cluster ts.net stub and no s3-egress proxy Service — the
# FQDN below is resolved directly and gated on private IPs.
S3_FQDN="{{ .fqdn }}"
SVC_HOST="$S3_FQDN"
ENDPOINT="https://$S3_FQDN"
S3_PORT="443"
BUCKET="{{ .bucket }}"
if [ -z "$AWS_ACCESS_KEY_ID" ] || [ -z "$AWS_SECRET_ACCESS_KEY" ]; then
  echo "[{{ $tag }}] ERROR: could not parse credentials from $CRED_FILE"
  echo "[{{ $tag }}] File content (sanitized):"
  sed 's/=.*/=***/' "$CRED_FILE" || cat "$CRED_FILE" || true
  exit 1
fi
# Wait for the tailnet FQDN to resolve via node MagicDNS
echo "[{{ $tag }}] Waiting for $SVC_HOST (max 120s)..."
DNS_WAIT=0
DNS_MAX=120
while [ $DNS_WAIT -lt $DNS_MAX ]; do
  if nslookup "$SVC_HOST" >/dev/null 2>&1 || getent hosts "$SVC_HOST" >/dev/null 2>&1; then
    break
  fi
  echo "[{{ $tag }}] DNS not yet resolved ($DNS_WAIT/$DNS_MAX s)..."
  sleep 5
  DNS_WAIT=$((DNS_WAIT + 5))
done
if [ $DNS_WAIT -ge $DNS_MAX ]; then
  echo "[{{ $tag }}] WARNING: DNS still not resolved after $DNS_MAX s — one final resolution attempt below before failing fast"
fi
# Pre-s3api endpoint validation: log every SVC-resolved IP:port
# BEFORE any aws call, and fail fast if any resolved IP is
# public. Private = 10/8 (pod/service nets), 100.64/10
is_private_ip() {
  _pip="$1"
  case "$_pip" in
    10.*|192.168.*) return 0 ;;
    100.*)
      _prest="${_pip#*.}"
      _psecond="${_prest%%.*}"
      case "$_psecond" in ''|*[!0-9]*) return 1 ;; esac
      if [ "$_psecond" -ge 64 ] && [ "$_psecond" -le 127 ]; then return 0; fi
      return 1 ;;
    fd*|FD*) return 0 ;;
    *) return 1 ;;
  esac
}
# Best-effort TLS probe: openssl shows the handshake, curl shows the
# HTTP layer. Both are guarded (image may lack either) and never fail
# the Job — they only add evidence to the log.
tls_probe() {
  _host="$1"; _ip="$2"
  if command -v openssl >/dev/null 2>&1; then
    echo "[{{ $tag }}] TLS diagnostic (best-effort): openssl s_client -connect $_ip:$S3_PORT -servername $_host"
    if command -v timeout >/dev/null 2>&1; then
      timeout 10 openssl s_client -connect "$_ip:$S3_PORT" -servername "$_host" </dev/null 2>&1 | head -30 || true
    else
      openssl s_client -connect "$_ip:$S3_PORT" -servername "$_host" </dev/null 2>&1 | head -30 || true
    fi
  else
    echo "[{{ $tag }}] openssl not available — skipping openssl probe"
  fi
  if command -v curl >/dev/null 2>&1; then
    echo "[{{ $tag }}] TLS diagnostic (best-effort): curl -vk https://$_host/ (SNI)"
    curl -vk --max-time 10 "https://$_host/" 2>&1 | head -30 || true
  else
    echo "[{{ $tag }}] curl not available — skipping curl probe"
  fi
}
RESOLVED_IPS="$( (getent hosts "$SVC_HOST" 2>/dev/null | awk '{print $1}'; nslookup "$SVC_HOST" 2>/dev/null | awk '/^Address: /{if ($2 !~ /#/) print $2} /^Address [0-9]+:/{print $3}') | sort -u | tr '\n' ' ' || true )"
if [ -z "$(echo "$RESOLVED_IPS" | tr -d '[:space:]')" ]; then
  echo "[{{ $tag }}] ERROR: no IP resolved for $SVC_HOST — refusing aws s3api call (check kube-dns forwarding and tailscaled MagicDNS on the node)"
  exit 1
fi
for RIP in $RESOLVED_IPS; do
  echo "[{{ $tag }}] egress $SVC_HOST -> $RIP, dialing https://$S3_FQDN (SNI)"
  if is_private_ip "$RIP"; then
    echo "[{{ $tag }}] $RIP is private (10/8, 100.64/10, 192.168/16, fd00::/8) — OK"
  else
    echo "[{{ $tag }}] ERROR: refusing S3 dial — $RIP is PUBLIC (outside 10/8, 100.64/10, 192.168/16, fd00::/8); expected the tailnet 100.x IP from node MagicDNS, not a public fallback"
    tls_probe "$S3_FQDN" "$RIP"
    exit 1
  fi
done
# SNI fix: pin the LE-cert FQDN to the in-cluster svc IPs
# resolved above — runtime /etc/hosts entries, never static
for RIP in $RESOLVED_IPS; do
  echo "[{{ $tag }}] hosts-pin: $RIP $S3_FQDN"
  echo "$RIP $S3_FQDN" >> /etc/hosts
done

echo "[{{ $tag }}] Checking bucket $BUCKET at $ENDPOINT (region $AWS_DEFAULT_REGION)..."

# RustFS serves a public Let's Encrypt cert for $S3_FQDN, but
# --no-verify-ssl is retained (robustness across rotations).
# NOTE: --no-verify-ssl skips CERT validation only — the TLS handshake
# still runs. A fail-closed backend (packet filter / dead sidecar)
# surfaces here as SSL UNEXPECTED_EOF, never as a cert error.

# Idempotent: head-bucket first; create only on 404/NoSuchBucket.
set +e
HEAD_OUTPUT="$(aws --no-verify-ssl s3api head-bucket --bucket "$BUCKET" --endpoint-url "$ENDPOINT" --region "$AWS_DEFAULT_REGION" 2>&1)"
HEAD_RC=$?
set -e
# Always log the full head-bucket output: the classifier below is
# heuristic, and the raw text is the evidence that survives via the
# (long) ttlSecondsAfterFinished.
echo "[{{ $tag }}] head-bucket exit=$HEAD_RC output:"
echo "$HEAD_OUTPUT"
if [ $HEAD_RC -eq 0 ]; then
  echo "[{{ $tag }}] Bucket $BUCKET ready (already existed)."
elif echo "$HEAD_OUTPUT" | grep -qiE 'UNEXPECTED_EOF|EOF occurred|SSLError|TLS|handshake failure|Connection reset|Connection refused|timed out|Timeout|EndpointConnectionError|Max retries exceeded|Could not connect|Network is unreachable'; then
  echo "[{{ $tag }}] ERROR: TLS/network failure reaching $ENDPOINT (exit $HEAD_RC)."
  echo "[{{ $tag }}] This is a BACKEND outage, not an IAM or bucket problem: the TCP/TLS layer died before S3 answered."
  echo "[{{ $tag }}] Check the RustFS host (serve.json, rustfs-ts tailscaled sidecar packet filter, :443 listener) — the Job DNS/IP-guard/hosts-pin above already passed."
  for RIP in $RESOLVED_IPS; do
    tls_probe "$S3_FQDN" "$RIP"
  done
  exit $HEAD_RC
elif echo "$HEAD_OUTPUT" | grep -qiE '404|NoSuchBucket|NotFound'; then
  echo "[{{ $tag }}] Creating bucket $BUCKET at $ENDPOINT (region $AWS_DEFAULT_REGION)..."
  set +e
  OUTPUT="$(aws --no-verify-ssl s3api create-bucket --bucket "$BUCKET" --endpoint-url "$ENDPOINT" --region "$AWS_DEFAULT_REGION" 2>&1)"
  RC=$?
  set -e
  if [ $RC -eq 0 ]; then
    echo "[{{ $tag }}] Bucket created successfully."
  elif echo "$OUTPUT" | grep -qiE 'BucketAlreadyOwnedByYou|BucketAlreadyExists|already exists'; then
    echo "[{{ $tag }}] Bucket $BUCKET ready (already existed)."
  else
    echo "[{{ $tag }}] create-bucket exit=$RC output:"
    echo "$OUTPUT"
    if echo "$OUTPUT" | grep -qiE 'UNEXPECTED_EOF|EOF occurred|SSLError|TLS|Connection reset|Connection refused|timed out|EndpointConnectionError|Max retries exceeded|Could not connect'; then
      echo "[{{ $tag }}] ERROR: TLS/network failure during create-bucket — BACKEND outage (see note above), not IAM."
      for RIP in $RESOLVED_IPS; do
        tls_probe "$S3_FQDN" "$RIP"
      done
    elif echo "$OUTPUT" | grep -qiE 'AccessDenied|403|Forbidden'; then
      echo "[{{ $tag }}] ERROR: create-bucket denied — grant s3:CreateBucket on arn:aws:s3:::$BUCKET (see docs/rustfs-iam.md) or pre-create the bucket."
    else
      echo "[{{ $tag }}] ERROR: create-bucket failed with exit $RC"
    fi
    exit $RC
  fi
else
  if echo "$HEAD_OUTPUT" | grep -qiE 'AccessDenied|403|Forbidden'; then
    echo "[{{ $tag }}] ERROR: head-bucket denied AND bucket not confirmed — grant s3:CreateBucket on arn:aws:s3:::$BUCKET (see docs/rustfs-iam.md) or pre-create the bucket."
  else
    echo "[{{ $tag }}] ERROR: head-bucket failed with exit $HEAD_RC (unclassified — raw output logged above)"
  fi
  exit $HEAD_RC
fi

echo "[{{ $tag }}] Verifying bucket with head-bucket..."
aws --no-verify-ssl s3api head-bucket --bucket "$BUCKET" --endpoint-url "$ENDPOINT" --region "$AWS_DEFAULT_REGION"
echo "[{{ $tag }}] Verification OK — bucket $BUCKET is accessible."
aws --no-verify-ssl s3 ls "s3://$BUCKET/" --endpoint-url "$ENDPOINT" --region "$AWS_DEFAULT_REGION" || true
echo "[{{ $tag }}] Done."
{{- end }}
