#!/usr/bin/env bash
# ShellCheck all repo shell scripts.
# Shared by CI (ci.yaml validate job) and local `just validate-scripts`.
# Local (default): soft-skips when shellcheck is not installed.
# CI: set SCRIPTS_STRICT=1 so a missing shellcheck fails the step.
set -euo pipefail
cd "$(dirname "$0")/.."

scripts=(
  bootstrap/init-gitops.sh
  platform/vault/scripts/bootstrap-vault.sh
)
for f in scripts/*.sh; do [ -e "$f" ] && scripts+=("$f"); done

if ! command -v shellcheck >/dev/null 2>&1; then
  if [ "${SCRIPTS_STRICT:-0}" = "1" ]; then
    echo "❌ shellcheck not found but SCRIPTS_STRICT=1 — install or fix the CI setup step" >&2
    exit 1
  fi
  echo "⚠️  shellcheck not found — skipping (install with: sudo apt install shellcheck / brew install shellcheck)"
  echo "   CI will still run shellcheck; local check is non-blocking"
  exit 0
fi

shellcheck --version
# -x: follow sourced files (source= directives resolve relative to repo root)
for s in "${scripts[@]}"; do
  echo "==> shellcheck $s"
  shellcheck -x "$s"
done
echo "✅ validate-scripts: OK"
