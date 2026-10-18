#!/usr/bin/env bash
# Create/update the Tailscale operator Secret AND restart the operator so it
# picks up rotation. Idempotent; skips with a warning when credentials are
# missing or still placeholders.
# Inputs via env: K8S_TS_OAUTH_CLIENT_ID / K8S_TS_OAUTH_SECRET
# Shared by CI (deploy.yaml "Ensure Tailscale Operator Secret") and
# local `just secrets-apply`. Requires kubectl pointed at the target cluster
# (KUBECONFIG or in-cluster context).
set -euo pipefail

TS_ID="${K8S_TS_OAUTH_CLIENT_ID:-}"
TS_SECRET="${K8S_TS_OAUTH_SECRET:-}"
if [ -z "$TS_ID" ] || [ -z "$TS_SECRET" ] || [ "$TS_ID" = "..." ] || [ "$TS_SECRET" = "..." ]; then
  echo "  ⏭️  Tailscale: no valid credentials (K8S_TS_OAUTH_CLIENT_ID / K8S_TS_OAUTH_SECRET) — skipping"
  echo "     Tip: fill in .env and retry, or export the vars in the shell"
  exit 0
fi

echo "  🔐 Tailscale: creating/updating Secret tailscale/operator-oauth..."
kubectl get namespace tailscale >/dev/null 2>&1 || kubectl create namespace tailscale >/dev/null 2>&1
kubectl create secret generic operator-oauth \
  --namespace tailscale \
  --from-literal=client_id="$TS_ID" \
  --from-literal=client_secret="$TS_SECRET" \
  --dry-run=client -o yaml | kubectl apply -f - >/dev/null
echo "  ✅ Tailscale: Secret tailscale/operator-oauth ready"
kubectl rollout restart deployment/tailscale-operator -n tailscale >/dev/null 2>&1 || \
  kubectl rollout restart deployment/operator -n tailscale >/dev/null 2>&1 || true
