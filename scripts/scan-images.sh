#!/usr/bin/env bash
# LOCAL trivy image scan of every image discovered from charts + source.
# Mirrors the CI trivy-images gate: digest-pinned images (pinned.json) fail
# the gate on HIGH/CRITICAL findings; upstream images are advisory only.
# The authoritative CI run lives in ci.yaml (trivy-action + SARIF upload);
# this script is the local mirror — soft-skips without trivy.
set -euo pipefail
cd "$(dirname "$0")/.."

if ! command -v trivy >/dev/null 2>&1; then
  echo "⚠️  trivy not found — skipping (install with: https://aquasecurity.github.io/trivy/latest/getting-started/installation/)"
  echo "   CI still runs trivy in security.yaml; local check is non-blocking"
  exit 0
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "⚠️  jq not found — summary needs it (showing full tables instead)"
  JQ=0
else
  JQ=1
fi

out="$(mktemp -d)"
# shellcheck disable=SC2064
trap "rm -rf '$out'" EXIT
./scripts/discover-images.sh "$out" | sed 's/^/   /'

images_count="$(jq 'length' "$out/images.json")"
echo "==> scan: scanning $images_count image(s) (pinned first-party images block, others advisory)"
failed=0
advisory=0
if [ "$JQ" = "1" ]; then printf '%-42s %8s %8s %8s\n' IMAGE CRITICAL HIGH TOTAL; fi
while IFS= read -r image; do
  scan_out="$(mktemp)"
  # --exit-code 1: findings must flip the summary (trivy defaults to 0).
  # --ignore-unfixed + --scanners vuln: cut unactionable noise.
  if trivy image --severity HIGH,CRITICAL --ignore-unfixed --scanners vuln --exit-code 1 --format json --output "$scan_out" --quiet "$image" >/dev/null 2>&1; then
    crit=0; high=0
  else
    is_pinned="$(jq -r --arg i "$image" 'any(.[]; . == $i)' "$out/pinned.json")"
    if [ "$is_pinned" = "true" ]; then
      failed=1
    else
      advisory=1
    fi
    crit=0; high=0
    if [ "$JQ" = "1" ]; then
      crit=$(jq '[.Results[]?.Vulnerabilities[]? | select(.Severity=="CRITICAL")] | length' "$scan_out" 2>/dev/null || echo "?")
      high=$(jq '[.Results[]?.Vulnerabilities[]? | select(.Severity=="HIGH")] | length' "$scan_out" 2>/dev/null || echo "?")
    fi
  fi
  if [ "$JQ" = "1" ]; then
    total=$((crit + high))
    printf '%-42s %8s %8s %8s\n' "$image" "$crit" "$high" "$total"
  fi
  rm -f "$scan_out"
done < <(jq -r '.[]' "$out/images.json")

if [ "$advisory" != "0" ]; then
  echo "⚠️  scan: upstream (advisory) findings above — fixed only by upstream releases; tracked via CI SARIF + Trivy Operator"
fi
if [ "$failed" != "0" ]; then
  echo "❌ scan: pinned-image HIGH/CRITICAL findings above fail the gate (mirrors CI Security fail-closed; conscious accepts go in .trivyignore with justification)"
  exit 1
else
  echo "✅ scan: OK (pinned images clean)"
fi
