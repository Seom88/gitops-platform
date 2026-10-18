#!/usr/bin/env bash
# Enforce inline image convention (no split repository:/tag: in values files).
# Shared by CI (ci.yaml validate job) and local `just validate-images`.
set -euo pipefail
cd "$(dirname "$0")/.."

# Convention: first-party values files must use single-line inline
# `image: <repo>:<tag>[@<digest>]` so Renovate Manager 1 owns every
# image line. Split blocks (`repository:` + `tag:` keys) are invisible
# to Manager 1 and silently skip Renovate updates — fail on them.
# Scope is values*.yaml only: Chart.yaml `repository:` (chart
# dependencies) and vendored charts are intentionally out of scope.

matches="$(grep -rn --include='values*.yaml' -E '^[[:space:]]*repository[[:space:]]*:' platform/ apps/ gitops/ || true)"
if [ -n "$matches" ]; then
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    echo "::error::split-style image blocks found in values files (use inline 'image: <repo>:<tag>' instead):"
  else
    echo "❌ split-style image blocks found in values files (use inline 'image: <repo>:<tag>' instead):" >&2
  fi
  printf '%s\n' "$matches"
  exit 1
fi
echo "✅ Inline image convention: OK (no 'repository:' keys in values*.yaml)"
