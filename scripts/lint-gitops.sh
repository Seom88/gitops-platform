#!/usr/bin/env bash
# Validate the GitOps App-of-Apps chart: dependency build, helm lint (prod/dev),
# helm template (prod/dev) with empty-render checks.
# Shared by CI (ci.yaml validate job) and local `just validate-gitops`.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> helm dependency build (gitops)"
helm dependency build gitops 2>&1 || echo "no dependencies to build for gitops chart"

echo "==> helm lint (prod)"
helm lint gitops -f gitops/values.yaml --set sharedS3.tailnetFqdn=s3-validate.invalid
echo "==> helm lint (dev)"
helm lint gitops -f gitops/values-dev.yaml --set sharedS3.tailnetFqdn=s3-validate.invalid

tmp_prod="$(mktemp)"
tmp_dev="$(mktemp)"
trap 'rm -f "$tmp_prod" "$tmp_dev"' EXIT

echo "==> helm template (prod) — empty check"
helm template gitops gitops -f gitops/values.yaml --set sharedS3.tailnetFqdn=s3-validate.invalid > "$tmp_prod"
test -s "$tmp_prod" || { echo "❌ helm template rendered empty (prod)" >&2; exit 1; }
echo "   prod render: $(wc -l < "$tmp_prod") lines, $(grep -c '^---' "$tmp_prod" || true) documents"
if [ -n "${GITHUB_ACTIONS:-}" ]; then head -n 80 "$tmp_prod"; fi

echo "==> helm template (dev) — empty check"
helm template gitops gitops -f gitops/values-dev.yaml --set sharedS3.tailnetFqdn=s3-validate.invalid > "$tmp_dev"
test -s "$tmp_dev" || { echo "❌ helm template rendered empty (dev)" >&2; exit 1; }
echo "   dev render: $(wc -l < "$tmp_dev") lines"

echo "✅ validate-gitops: OK"
