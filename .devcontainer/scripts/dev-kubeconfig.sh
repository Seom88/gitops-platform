#!/usr/bin/env bash
# Prepare the devcontainer kubeconfigs on the host (docs: docs/devcontainer.md,
# ADR-025). Runs automatically from devcontainer.json `initializeCommand`
# before the container is created and on subsequent starts; also available as
# `just dev-kubeconfig` for a manual refresh.
#
# It stages two independent credentials under $HOME/.kube/devcontainer:
#   prod/kubeconfig  read-only ServiceAccount `dev-agents` + bounded token
#   dev/kubeconfig   copy of the full-access dev cluster kubeconfig
# devcontainer.json mounts the prod and dev subdirectories read-only at
# /home/vscode/.kubeconfigs/{prod,dev}.
#
# Inputs via env (normally loaded from the repo-root .env):
#   DEVCONTAINER_PROD_ADMIN_KUBECONFIG  admin kubeconfig for the prod cluster
#                                       (default: the current kubectl context)
#   DEVCONTAINER_DEV_KUBECONFIG         dev cluster kubeconfig (copied as-is)
#   DEVCONTAINER_API_SERVER             API server URL override
#   DEVCONTAINER_TOKEN_DURATION         token TTL (default 24h; if the API
#                                       rejects it, retries once without it)
#
# Missing env vars/files only warn: the container still starts and kubectl
# ignores the missing KUBECONFIG entry. Security violations (paths inside the
# repo, dev pointing at the prod admin credential) are refused or skipped.
#
# Prod TLS: embedded certificate-authority-data, a readable certificate-authority
# file, or the host/container system trust store. insecure-skip-tls-verify is
# refused on purpose.
set -euo pipefail
umask 077

STAGE_ROOT="$HOME/.kube/devcontainer"
PROD_DIR="$STAGE_ROOT/prod"
DEV_DIR="$STAGE_ROOT/dev"
PROD_OUT="$PROD_DIR/kubeconfig"
DEV_OUT="$DEV_DIR/kubeconfig"

PROD_SERVER=""
PROD_MINTED_AT=""
PROD_DURATION=""
DEV_SOURCE=""

warn() {
  printf '  ⚠️  %s\n' "$*" >&2
}

fail() {
  printf '  ❌ %s\n' "$*" >&2
}

expand_path() {
  if [ "$1" = "~" ]; then
    printf '%s' "$HOME"
  elif [[ "$1" == \~/* ]]; then
    printf '%s/%s' "$HOME" "${1:2}"
  else
    printf '%s' "$1"
  fi
}

# ============================================================================
# Resolve the repo root and load .env when invoked directly (not via `just`)
# ============================================================================
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [ -z "$REPO_ROOT" ]; then
  fail "Could not resolve the repository root — run this script from the repo checkout"
  exit 1
fi
REPO_ROOT="$(realpath "$REPO_ROOT")"
ENV_FILE="$REPO_ROOT/.env"
if [ -f "$ENV_FILE" ]; then
  # Load .env in a subshell and export only the devcontainer kubeconfig
  # settings; API keys and other secrets must not leak into kubectl's
  # environment.
  eval "$(
    set -a
    # shellcheck disable=SC1090
    . "$ENV_FILE"
    set +a
    for _var in \
      DEVCONTAINER_PROD_ADMIN_KUBECONFIG \
      DEVCONTAINER_DEV_KUBECONFIG \
      DEVCONTAINER_API_SERVER \
      DEVCONTAINER_TOKEN_DURATION; do
      if [ -n "${!_var+x}" ]; then
        printf 'export %s=%q\n' "$_var" "${!_var}"
      fi
    done
  )"
fi

is_inside_repo() {
  local resolved
  resolved="$(realpath -m "$1")"
  [ "$resolved" = "$REPO_ROOT" ] || [[ "$resolved" == "$REPO_ROOT/"* ]]
}

# ============================================================================
# Staging directory (must never live inside the mounted workspace)
# ============================================================================
mkdir -p "$PROD_DIR" "$DEV_DIR"
chmod 700 "$STAGE_ROOT" "$PROD_DIR" "$DEV_DIR"
STAGE_ROOT_REAL="$(realpath "$STAGE_ROOT")"
if is_inside_repo "$STAGE_ROOT"; then
  fail "Staging directory $STAGE_ROOT resolves inside the repo tree ($REPO_ROOT)"
  exit 1
fi

# Any file under STAGE_ROOT is bind-mounted into the container, so the prod
# admin kubeconfig must never live there.
is_inside_stage() {
  local resolved
  resolved="$(realpath -m "$1")"
  [ "$resolved" = "$STAGE_ROOT_REAL" ] || [[ "$resolved" == "$STAGE_ROOT_REAL/"* ]]
}

# ============================================================================
# Prod: mint a bounded token for ServiceAccount dev-agents
# Returns 0 on success, 1 on a skippable failure, 2 on a security violation.
# ============================================================================
prepare_prod() {
  local admin="${DEVCONTAINER_PROD_ADMIN_KUBECONFIG:-}"
  local server admin_server api_server server_host api_host
  local node_name node_ip
  local ca ca_file insecure tls_server_name token duration minted_at ca_tmp tmp
  local -a set_cluster_args

  if [ -n "$admin" ]; then
    admin="$(expand_path "$admin")"
    if is_inside_stage "$admin"; then
      fail "DEVCONTAINER_PROD_ADMIN_KUBECONFIG must not be inside the staging directory ($STAGE_ROOT)"
      fail "That directory is mounted into the devcontainer; keep the admin kubeconfig outside it"
      return 2
    fi
    if [ ! -f "$admin" ]; then
      warn "DEVCONTAINER_PROD_ADMIN_KUBECONFIG not found: $admin — skipping prod kubeconfig"
      return 1
    fi
    if is_inside_repo "$admin"; then
      fail "DEVCONTAINER_PROD_ADMIN_KUBECONFIG resolves inside the repo tree ($REPO_ROOT)"
      fail "The devcontainer mounts the workspace; keep the prod admin kubeconfig outside the repo"
      return 2
    fi
    export KUBECONFIG="$admin"
  fi

  if ! kubectl get sa dev-agents -n tailscale >/dev/null 2>&1; then
    warn "ServiceAccount dev-agents -n tailscale not found in the prod cluster — skipping prod kubeconfig"
    warn "The read-only RBAC ships in platform/ts-operator/templates/users/ and is applied by ArgoCD"
    return 1
  fi

  server="$(kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)"
  ca="$(kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority-data}' 2>/dev/null || true)"
  ca_file="$(kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.certificate-authority}' 2>/dev/null || true)"
  insecure="$(kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.insecure-skip-tls-verify}' 2>/dev/null || true)"
  tls_server_name="$(kubectl config view --raw --minify -o jsonpath='{.clusters[0].cluster.tls-server-name}' 2>/dev/null || true)"
  if [ -z "$server" ]; then
    warn "No server found in the prod kubectl context — skipping prod kubeconfig"
    return 1
  fi
  if [ "$insecure" = "true" ]; then
    warn "Prod kubeconfig uses insecure-skip-tls-verify — refusing to stage a prod credential"
    warn "Configure certificate-authority-data or a trusted certificate-authority file instead"
    return 2
  fi
  admin_server="$server"
  if [ -n "${DEVCONTAINER_API_SERVER:-}" ]; then
    api_server="$DEVCONTAINER_API_SERVER"
    api_host="${api_server#*://}"
    api_host="${api_host%%/*}"
    api_host="${api_host%%:*}"
    if [[ "$api_host" == *.ts.net ]]; then
      warn "DEVCONTAINER_API_SERVER points at a Tailscale MagicDNS name ($api_server)"
      warn "That proxy authenticates with your Tailscale identity and ignores the ServiceAccount token"
      warn "Use the control-plane Tailscale IP instead (e.g. https://<ip>:6443)"
      return 2
    fi
  else
    server_host="${admin_server#*://}"
    server_host="${server_host%%/*}"
    server_host="${server_host%%:*}"
    if [[ "$server_host" == *.ts.net ]]; then
      node_name="$(kubectl get nodes -l node-role.kubernetes.io/control-plane -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
      if [ -z "$node_name" ]; then
        node_name="$(kubectl get nodes -l node-role.kubernetes.io/master -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
      fi
      if [ -n "$node_name" ] && command -v tailscale >/dev/null 2>&1; then
        node_ip="$(tailscale ip -4 "$node_name" 2>/dev/null | head -n1 || true)"
        if [ -z "$node_ip" ]; then
          node_ip="$(tailscale status 2>/dev/null | awk -v n="$node_name" '$2 == n { print $1; exit }')"
        fi
      fi
      if [ -z "$node_ip" ]; then
        warn "Prod admin kubeconfig points at the Tailscale API server proxy ($admin_server)"
        warn "That proxy authenticates with your Tailscale identity and ignores the ServiceAccount token"
        warn "Set DEVCONTAINER_API_SERVER to the direct API server (e.g. https://<control-plane-tailscale-ip>:6443)"
        return 1
      fi
      api_server="https://$node_ip:6443"
      printf '  ℹ️  Prod admin uses the Tailscale proxy; staging the direct API server %s\n' "$api_server"
    else
      api_server="$admin_server"
    fi
  fi
  server="$api_server"

  if [ "$api_server" != "$admin_server" ]; then
    ca=""
    ca_file=""
    tls_server_name=""
  fi

  if [ -z "$ca" ] && [ -n "$ca_file" ]; then
    case "$ca_file" in
      /*) ;;
      *)
        if [ -n "$admin" ]; then
          ca_file="$(dirname "$admin")/$ca_file"
        else
          ca_file="$HOME/.kube/$ca_file"
        fi
        ;;
    esac
    if [ ! -f "$ca_file" ]; then
      warn "Certificate authority file not found: $ca_file — skipping prod kubeconfig"
      return 1
    fi
  fi

  if [ "$api_server" != "$admin_server" ] && [ -z "$ca" ] && [ -z "$ca_file" ]; then
    if ca="$(kubectl get configmap kube-root-ca.crt -n default -o jsonpath='{.data.ca\.crt}' 2>/dev/null | base64 | tr -d '\n')" && [ -n "$ca" ]; then
      printf '  ℹ️  Using kube-root-ca.crt for the direct API server\n'
    else
      ca=""
      warn "Could not read kube-root-ca.crt for the direct API server; relying on the system CA"
    fi
  fi

  duration="${DEVCONTAINER_TOKEN_DURATION:-24h}"
  minted_at="$(date -Iseconds)"

  if ! token="$(kubectl create token dev-agents -n tailscale --duration="$duration" 2>/dev/null)"; then
    warn "Token duration $duration rejected by the API — minting without --duration (≈1h)"
    if ! token="$(kubectl create token dev-agents -n tailscale 2>/dev/null)"; then
      warn "Could not mint a token for ServiceAccount dev-agents — skipping prod kubeconfig"
      return 1
    fi
    duration=""
  fi

  tmp="$(mktemp "$PROD_DIR/.kubeconfig.XXXXXX")"
  ca_tmp=""
  if [ -n "$ca" ]; then
    ca_tmp="$(mktemp "${TMPDIR:-/tmp}/devcontainer-ca.XXXXXX")"
    if ! printf '%s' "$ca" | base64 -d > "$ca_tmp"; then
      rm -f "$tmp" "$ca_tmp"
      warn "Could not decode the cluster CA — skipping prod kubeconfig"
      return 1
    fi
  elif [ -n "$ca_file" ]; then
    ca_tmp="$(mktemp "${TMPDIR:-/tmp}/devcontainer-ca.XXXXXX")"
    if ! cp -- "$ca_file" "$ca_tmp"; then
      rm -f "$tmp" "$ca_tmp"
      warn "Could not read the cluster CA file — skipping prod kubeconfig"
      return 1
    fi
  fi

  set_cluster_args=(--server="$server")
  if [ -n "$ca_tmp" ]; then
    set_cluster_args+=(--certificate-authority="$ca_tmp" --embed-certs=true)
  fi
  if [ -n "$tls_server_name" ]; then
    set_cluster_args+=(--tls-server-name="$tls_server_name")
  fi
  if ! kubectl config --kubeconfig="$tmp" set-cluster prod "${set_cluster_args[@]}"; then
    if [ -n "$ca_tmp" ]; then
      rm -f "$tmp" "$ca_tmp"
    else
      rm -f "$tmp"
    fi
    warn "Could not write the prod kubeconfig — skipping prod kubeconfig"
    return 1
  fi
  if [ -n "$ca_tmp" ]; then
    rm -f "$ca_tmp"
  fi
  if ! kubectl config --kubeconfig="$tmp" set-credentials dev-agents --token="$token"; then
    rm -f "$tmp"
    warn "Could not write the prod kubeconfig credentials — skipping prod kubeconfig"
    return 1
  fi
  if ! kubectl config --kubeconfig="$tmp" set-context prod-readonly \
    --cluster=prod \
    --user=dev-agents; then
    rm -f "$tmp"
    warn "Could not write the prod kubeconfig context — skipping prod kubeconfig"
    return 1
  fi
  if ! kubectl config --kubeconfig="$tmp" use-context prod-readonly; then
    rm -f "$tmp"
    warn "Could not select the prod kubeconfig context — skipping prod kubeconfig"
    return 1
  fi
  chmod 600 "$tmp"
  mv -f "$tmp" "$PROD_OUT"

  PROD_SERVER="$server"
  PROD_MINTED_AT="$minted_at"
  PROD_DURATION="$duration"
  return 0
}

# ============================================================================
# Dev: copy the full-access kubeconfig as-is (never the prod admin file)
# ============================================================================
prepare_dev() {
  local src="${DEVCONTAINER_DEV_KUBECONFIG:-}"
  local src_real candidate tmp
  local -a admin_candidates=()

  if [ -z "$src" ]; then
    warn "DEVCONTAINER_DEV_KUBECONFIG is unset — skipping dev kubeconfig"
    return 1
  fi
  src="$(expand_path "$src")"
  if [ ! -f "$src" ]; then
    warn "DEVCONTAINER_DEV_KUBECONFIG not found: $src — skipping dev kubeconfig"
    return 1
  fi
  if is_inside_repo "$src"; then
    warn "DEVCONTAINER_DEV_KUBECONFIG resolves inside the repo tree — skipping dev kubeconfig"
    return 1
  fi

  if is_inside_stage "$src"; then
    warn "DEVCONTAINER_DEV_KUBECONFIG must not be inside the staging directory — skipping dev kubeconfig"
    return 1
  fi
  src_real="$(realpath "$src")"

  # Compare against the admin file(s) kubectl could be using: the explicit
  # path, every entry in KUBECONFIG, and the default ~/.kube/config.
  if [ -n "${KUBECONFIG:-}" ]; then
    IFS=':' read -r -a admin_candidates <<< "$KUBECONFIG"
  fi
  admin_candidates+=("$HOME/.kube/config")
  for candidate in "${admin_candidates[@]}"; do
    [ -n "$candidate" ] || continue
    if [ "$src_real" = "$(realpath -m "$candidate")" ]; then
      warn "DEVCONTAINER_DEV_KUBECONFIG is a prod admin kubeconfig — skipping dev kubeconfig"
      return 1
    fi
  done

  tmp="$(mktemp "$DEV_DIR/.kubeconfig.XXXXXX")"
  if ! cp -- "$src" "$tmp"; then
    rm -f "$tmp"
    warn "Could not copy the dev kubeconfig — skipping dev kubeconfig"
    return 1
  fi
  chmod 600 "$tmp"
  mv -f "$tmp" "$DEV_OUT"

  DEV_SOURCE="$src"
  return 0
}

# ============================================================================
# Report (token never echoed)
# ============================================================================
format_expiry() {
  local duration="$1" minted="$2" num secs expires
  if [ -n "$duration" ] && [[ "$duration" =~ ^([0-9]+)([smhd]?)$ ]]; then
    num="${BASH_REMATCH[1]}"
    case "${BASH_REMATCH[2]}" in
      ""|s) secs="$num" ;;
      m) secs=$((num * 60)) ;;
      h) secs=$((num * 3600)) ;;
      d) secs=$((num * 86400)) ;;
    esac
    if expires="$(date -d "$minted + $secs seconds" -Iseconds 2>/dev/null)"; then
      printf 'expires %s (%s)' "$expires" "$duration"
      return
    fi
  fi
  if [ -n "$duration" ]; then
    printf 'minted %s (duration %s)' "$minted" "$duration"
  else
    printf 'minted %s, API-default TTL (≈1h)' "$minted"
  fi
}

prod_status=0
prepare_prod || prod_status=$?
if [ "$prod_status" -ne 0 ]; then
  rm -f "$PROD_OUT"
  if [ "$prod_status" -eq 2 ]; then
    exit 1
  fi
fi

dev_status=0
prepare_dev || dev_status=$?
if [ "$dev_status" -ne 0 ]; then
  rm -f "$DEV_OUT"
fi

echo "  ✅ Devcontainer kubeconfig preparation finished"
echo "     Staging: $STAGE_ROOT"
if [ "$prod_status" -eq 0 ]; then
  echo "     prod:    $PROD_OUT (read-only, $(format_expiry "$PROD_DURATION" "$PROD_MINTED_AT"))"
  echo "              server: $PROD_SERVER"
else
  echo "     prod:    not prepared (see warnings)"
fi
if [ "$dev_status" -eq 0 ]; then
  echo "     dev:     $DEV_OUT (full access, copied from $DEV_SOURCE)"
else
  echo "     dev:     not prepared (see warnings)"
fi
echo "     Mount:   /home/vscode/.kubeconfigs (read-only)"
