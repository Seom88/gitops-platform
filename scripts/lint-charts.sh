#!/usr/bin/env bash
# Lint charts with dependency resolution (helm repo ensure + deps + lint).
# Usage: lint-charts.sh <chart-dir>...  (dirs usually passed as globs, e.g. platform/*/ charts/*/)
# Shared by CI (ci.yaml validate job) and local `just validate-platform`.
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=./scripts/helm-repos.sh
source "$(dirname "$0")/helm-repos.sh"

if [ "$#" -eq 0 ]; then
  echo "usage: $0 <chart-dir>..." >&2
  exit 1
fi

helm_repos_ensure

failed=0
for dir in "$@"; do
  [ -f "${dir}Chart.yaml" ] || continue
  if [ -n "${GITHUB_ACTIONS:-}" ]; then
    echo "::group::helm lint $dir"
  else
    echo "==> helm lint $dir"
  fi
  # Use update to handle out-of-sync Chart.lock (e.g. vault)
  helm dependency update "$dir" 2>&1 || helm dependency build "$dir" 2>&1 || echo "   no deps / already built for $dir"
  # Velero and ts-operator require s3.tailnetFqdn (CI-supplied) — lint with a test value.
  extra=()
  if [ "$dir" = "platform/velero/" ] || [ "$dir" = "platform/ts-operator/" ]; then
    extra=(--set s3.tailnetFqdn=s3-validate.invalid)
  fi
  if ! helm lint "$dir" "${extra[@]}"; then
    if [ -n "${GITHUB_ACTIONS:-}" ]; then
      echo "::error::helm lint failed for $dir"
    else
      echo "❌ helm lint failed for $dir"
    fi
    failed=1
  fi
  if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::endgroup::"; fi
done
test "$failed" = "0" || exit 1
echo "✅ validate-platform: OK"
