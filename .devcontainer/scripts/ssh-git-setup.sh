#!/usr/bin/env bash
# ssh-git-setup.sh
# postStartCommand: prepare git-over-SSH for the devcontainer on every start.
#
# Only the host's ~/.ssh/id_ed25519 is bind-mounted read-only (at ~/.ssh/id_ed25519);
# the rest of ~/.ssh is not mounted, and nothing there is writable.
# We keep a writable, persistent known_hosts on a dedicated volume and point git/ssh at it,
# with StrictHostKeyChecking=accept-new so GitHub never triggers an interactive prompt.

set -euo pipefail

SSH_DIR=/home/vscode/.ssh
KH_DIR="${SSH_GIT_DIR:-/home/vscode/.ssh-known-hosts}"
KH_FILE="${KH_DIR}/known_hosts"
SSH_CONFIG="${KH_DIR}/ssh_config"
GIT_CONFIG="${KH_DIR}/gitconfig"

# 1) Writable known_hosts location (the mounted key is read-only).
if [ -n "${SSH_GIT_DIR:-}" ]; then
  install -d -m 700 "${KH_DIR}"
else
  install -d -m 700 -o vscode -g vscode "${KH_DIR}"
fi
[ -f "${KH_FILE}" ] || : > "${KH_FILE}"
chmod 644 "${KH_FILE}"

# Keep container-specific Git settings on this writable volume instead of
# assuming ~/.gitconfig is writable (it may be provided by the host or a mount).
export GIT_CONFIG_GLOBAL="${GIT_CONFIG}"

# 2) Pick a usable private key: GIT_SSH_KEY first, then well-known names, then
#    any other regular file that is not a known non-key. Every candidate is
#    validated with ssh-keygen unless ssh-keygen is unavailable.
KEY=""
KEY_NOTE=""

HAVE_SSH_KEYGEN=0
command -v ssh-keygen >/dev/null 2>&1 && HAVE_SSH_KEYGEN=1

is_blocklisted() {
  case "$(basename "$1")" in
    *.pub|authorized_keys|config|known_hosts|known_hosts.*|*_dss) return 0 ;;
  esac
  return 1
}

# Accept a candidate only if it is a readable regular file and a valid private key.
consider_key() {
  local candidate="$1"
  [ -f "${candidate}" ] || return 1
  [ -r "${candidate}" ] || return 1
  if [ "${HAVE_SSH_KEYGEN}" -eq 1 ]; then
    ssh-keygen -y -f "${candidate}" >/dev/null 2>&1 || return 1
  else
    KEY_NOTE=" (ssh-keygen unavailable; key accepted unvalidated)"
  fi
  KEY="${candidate}"
  return 0
}

if [ -n "${GIT_SSH_KEY:-}" ]; then
  consider_key "${GIT_SSH_KEY}" || \
    echo "⚠️  GIT_SSH_KEY='${GIT_SSH_KEY}' is not a readable, valid private key; falling back to detection." >&2
fi

if [ -z "${KEY}" ]; then
  for name in id_ed25519 id_rsa id_ecdsa id_dsa; do
    consider_key "${SSH_DIR}/${name}" && break
  done
fi

if [ -z "${KEY}" ]; then
  for f in "${SSH_DIR}"/*; do
    [ -f "${f}" ] || continue
    is_blocklisted "${f}" && continue
    consider_key "${f}" && break
  done
fi

if [ -z "${KEY}" ]; then
  echo "⚠️  No SSH identity for git: expose the host key at ~/.ssh/id_ed25519 (mounted at ${SSH_DIR}/id_ed25519) or set GIT_SSH_KEY." >&2
fi

# 3) Per-container ssh config: route github.com through our key, disable the
#    interactive host-key prompt, and use the writable known_hosts.
{
  echo "Host github.com"
  echo "    HostName github.com"
  echo "    User git"
  if [ -n "${KEY}" ]; then
    echo "    IdentityFile ${KEY}"
    echo "    IdentitiesOnly yes"
  fi
  echo "    StrictHostKeyChecking accept-new"
  echo "    UserKnownHostsFile ${KH_FILE}"
} > "${SSH_CONFIG}"
chmod 644 "${SSH_CONFIG}"

# 4) Tell git to use that ssh config for every host.
git config --global core.sshcommand "ssh -F ${SSH_CONFIG}"

# 5) Git identity: adopt it from the environment when provided, otherwise hint.
if [ -n "${GIT_USER_NAME:-}" ]; then git config --global user.name "${GIT_USER_NAME}"; fi
if [ -n "${GIT_USER_EMAIL:-}" ]; then git config --global user.email "${GIT_USER_EMAIL}"; fi
if ! git config --global user.name >/dev/null 2>&1; then
  echo "⚠️  git identity not set yet. Run:"
  echo "     git config --global user.name 'Tu nombre'"
  echo "     git config --global user.email 'tu@correo.com'"
fi

echo "✅ SSH+git ready: key=${KEY:-<default>}${KEY_NOTE}, known_hosts=${KH_FILE}"
