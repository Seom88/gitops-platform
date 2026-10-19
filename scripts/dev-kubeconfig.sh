#!/usr/bin/env bash
# Provision a dedicated, least-privilege kubeconfig for the AI-agent
# devcontainer (docs: docs/devcontainer.md, ADR-025).
#
# Runs MANUALLY on the host (never in CI): it requires an admin kubectl
# context (the k3s admin kubeconfig) to mint a bounded ServiceAccount token.
#
# What it produces (chmod 600, ALWAYS outside the repo tree):
#   ${DEVCONTAINER_KUBECONFIG_DIR:-$HOME/.config/devcontainer}/kubeconfig
# pointing the cluster API at a ServiceAccount `dev-agents` (read-only RBAC
# via platform/ts-operator/templates/users/*-dev-agents.yaml; no Secrets
# access) with a bounded token. This file is the ONLY credential the
# devcontainer will contain.
#
# Inputs via env:
#   DEVCONTAINER_API_SERVER     API server URL override (default: the current
#                               context's server; docs reference
#                               https://100.64.0.12:6443)
#   DEVCONTAINER_TOKEN_DURATION token TTL (default 24h; if the API rejects
#                               the duration, retries once without it and
#                               warns the token may expire in ~1h)
#   DEVCONTAINER_KUBECONFIG_DIR output dir (must NOT be inside the repo tree)
# Mirrors scripts/tailscale-secret.sh conventions. No repository-wide effects.
set -euo pipefail
umask 077

# ============================================================================
# Precondition: the dev-agents RBAC must already be applied to the cluster
# ============================================================================
if ! kubectl get sa dev-agents -n tailscale >/dev/null 2>&1; then
  echo "  ❌ ServiceAccount dev-agents -n tailscale not found in the cluster" >&2
  echo "     The read-only agent RBAC ships in the ts-operator chart" >&2
  echo "     (templates/users/*-dev-agents.yaml) and is applied by ArgoCD." >&2
  echo "     Fix: wait for the ArgoCD sync of the ts-operator chart and retry." >&2
  exit 1
fi

# ============================================================================
# Resolve the API server + CA data from the current admin context on the host
# ============================================================================
CURRENT_SERVER="$(kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.server}')"
CURRENT_CA_DATA="$(kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')"
if [ -z "$CURRENT_SERVER" ]; then
  echo "  ❌ No server found in the current kubectl context — point kubectl at the cluster first" >&2
  exit 1
fi
if [ -z "$CURRENT_CA_DATA" ]; then
  echo "  ❌ No certificate-authority-data found in the current kubectl context" >&2
  exit 1
fi

SERVER="${DEVCONTAINER_API_SERVER:-$CURRENT_SERVER}"
TOKEN_DURATION="${DEVCONTAINER_TOKEN_DURATION:-24h}"
MINTED_AT="$(date -Iseconds)"

# ============================================================================
# Mint a bounded token for ServiceAccount dev-agents
# NOTE: the token is visible in the process listing (e.g. /proc/*/cmdline)
# only while it is passed as `kubectl config set-credentials --token` below —
# a transient, minute-scale window on the human's own host; accepted tradeoff
# for a lambda-scoped read-only token. The token is NEVER echoed anywhere.
# ============================================================================
echo "  🔐 Devcontainer: minting bounded token for ServiceAccount dev-agents..."
if ! TOKEN="$(kubectl create token dev-agents -n tailscale --duration="$TOKEN_DURATION")"; then
  echo "  ⚠️  Token duration ${TOKEN_DURATION} rejected by the API — minting without --duration" >&2
  echo "     (the token may therefore expire in ~1h)" >&2
  TOKEN="$(kubectl create token dev-agents -n tailscale)"
  TOKEN_DURATION=""
fi

# ============================================================================
# Build the dedicated kubeconfig using kubectl config subcommands
# ============================================================================
REPO_ROOT="$(realpath "$(git rev-parse --show-toplevel 2>/dev/null || echo /nonexistent)" 2>/dev/null || true)"
if [ -z "$REPO_ROOT" ]; then
  echo "  ❌ Could not resolve the repository root — run this script from the repo checkout" >&2
  exit 1
fi
OUT_DIR="${DEVCONTAINER_KUBECONFIG_DIR:-$HOME/.config/devcontainer}"
OUT_PATH="$OUT_DIR/kubeconfig"
RESOLVED_OUT="$(realpath -m "$OUT_PATH")"
if [ "$RESOLVED_OUT" = "$REPO_ROOT" ] || { [ -n "$REPO_ROOT" ] && [[ "$RESOLVED_OUT" == "$REPO_ROOT/"* ]]; }; then
  echo "  ❌ Output path $OUT_PATH resolves inside the repo tree ($REPO_ROOT)" >&2
  echo "     The devcontainer mounts the workspace, so a kubeconfig inside the" >&2
  echo "     repo would sit under the same directory tree it is meant to isolate." >&2
  echo "     Pick a directory outside the repo (or leave DEVCONTAINER_KUBECONFIG_DIR unset)." >&2
  exit 1
fi
mkdir -p "$OUT_DIR"

KUBECFG_ARGS=(--kubeconfig="$OUT_PATH")
# kubectl config set-cluster takes the CA as a file (--certificate-authority);
# decode the base64 data to a temp file, embed it in the kubeconfig
# (--embed-certs), then remove the temp file.
CA_TMP="$(mktemp "${TMPDIR:-/tmp}/devcontainer-ca.XXXXXX")"
trap 'rm -f "$CA_TMP"' EXIT
printf '%s' "$CURRENT_CA_DATA" | base64 -d > "$CA_TMP"
kubectl config "${KUBECFG_ARGS[@]}" set-cluster devcontainer \
  --server="$SERVER" \
  --certificate-authority="$CA_TMP" \
  --embed-certs=true
kubectl config "${KUBECFG_ARGS[@]}" set-credentials dev-agents --token="$TOKEN"
kubectl config "${KUBECFG_ARGS[@]}" set-context devcontainer \
  --cluster=devcontainer \
  --user=dev-agents
kubectl config "${KUBECFG_ARGS[@]}" use-context devcontainer
chmod 600 "$OUT_PATH"

# ============================================================================
# Report (token never echoed)
# ============================================================================
# GNU date needs spelled-out units ("24 hours"), while kubectl accepts
# "24h"-style suffixes — normalize s/m/h/d suffixes into seconds for the
# expiry timestamp. Unrecognized forms (e.g. "1h30m") fall back to listing
# the raw duration instead of an absolute timestamp.
EXPIRES_AT=""
if [ -n "$TOKEN_DURATION" ] && [[ "$TOKEN_DURATION" =~ ^([0-9]+)([smhd]?)$ ]]; then
  DUR_NUM="${BASH_REMATCH[1]}"
  case "${BASH_REMATCH[2]}" in
    ""|s) DUR_SECS="$DUR_NUM" ;;
    m) DUR_SECS=$((DUR_NUM * 60)) ;;
    h) DUR_SECS=$((DUR_NUM * 3600)) ;;
    d) DUR_SECS=$((DUR_NUM * 86400)) ;;
  esac
  if EXPIRES_AT="$(date -d "$MINTED_AT + $DUR_SECS seconds" -Iseconds 2>/dev/null)"; then
    EXPIRY_LINE="Expiry:  $EXPIRES_AT (${TOKEN_DURATION})"
  fi
fi
: "${EXPIRY_LINE:=Expiry:  minted at $MINTED_AT, API-default TTL (≈1h)}"
echo "  ✅ Devcontainer kubeconfig ready"
echo "     Path:    $OUT_PATH (chmod 600)"
echo "     Server:  $SERVER"
echo "     $EXPIRY_LINE"
echo "     Note:    this file is the ONLY credential the devcontainer will contain"
