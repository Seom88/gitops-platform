#!/bin/bash
set -euo pipefail

: "${S3_ENDPOINT:?S3_ENDPOINT must be set (e.g. https://s3.<tailnet>.ts.net)}"
: "${SOPS_AGE_KEY_FILE:?SOPS_AGE_KEY_FILE must be set}"
: "${AWS_ACCESS_KEY_ID:?AWS_ACCESS_KEY_ID must be set (RustFS key)}"
: "${AWS_SECRET_ACCESS_KEY:?AWS_SECRET_ACCESS_KEY must be set (RustFS key)}"
for cmd in aws sops kubectl; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ERROR: '$cmd' not found in PATH" >&2; exit 1; }
done

mkdir -p "$(dirname "$SOPS_AGE_KEY_FILE")"
aws s3 cp s3://secrets-homelab/sops/keys.txt "$SOPS_AGE_KEY_FILE" \
    --endpoint-url "$S3_ENDPOINT" --region us-east-1 --no-verify-ssl
chmod 600 "$SOPS_AGE_KEY_FILE"

if find platform apps -path '*/templates/*' -name '*.enc.yaml' | grep -q .; then
  echo "::error::there are *.enc.yaml in templates/ — move them to <chart>/sops/"
  find platform apps -path '*/templates/*' -name '*.enc.yaml'
  exit 1
fi

mapfile -t files < <(find platform apps -name '*.enc.yaml' -not -path '*/templates/*' | sort)

# Velero first: on a bare cluster the restore path (BSL credentials) must land
# before anything else, and the velero namespace is guaranteed by init-gitops.sh.
# Every other file ensures its own namespace exists, so this script no longer
# dies with "namespaces ... not found" when ArgoCD hasn't synced yet.
velero=()
rest=()
for f in "${files[@]}"; do
  case "$f" in
    platform/velero/sops/*) velero+=("$f") ;;
    *) rest+=("$f") ;;
  esac
done

for f in "${velero[@]}" "${rest[@]}"; do
  echo "→ applying $f"
  tmp=$(mktemp)
  sops decrypt "$f" > "$tmp"
  # Indent-agnostic (some files use 4-space indent) and quote-stripping:
  # a quoted value would otherwise create a junk namespace literally named '"x"'.
  ns=$(awk '/^metadata:/{inmeta=1; next} /^[^[:space:]]/{inmeta=0} inmeta && /^[[:space:]]+namespace:[[:space:]]*[^[:space:]]/{v=$2; gsub(/["\047]/, "", v); print v; exit}' "$tmp")
  if [ -n "${ns:-}" ]; then
    kubectl get namespace "$ns" >/dev/null 2>&1 || kubectl create namespace "$ns"
  fi
  kubectl apply -f "$tmp"
  rm -f "$tmp"
done

shred -u "$SOPS_AGE_KEY_FILE" || rm -f "$SOPS_AGE_KEY_FILE"