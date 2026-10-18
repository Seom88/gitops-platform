#!/usr/bin/env bash
# JSON syntax sanity (python3 -m json.tool).
# Shared by CI (ci.yaml validate job) and local `just validate-json`.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> JSON sanity (python3 -m json.tool)"
errors=0
for f in $(find . -type f -name "*.json" -not -path "*/charts/*" -not -path "*/.git/*" -not -path "*/node_modules/*"); do
  echo "  checking $f..."
  if ! python3 -m json.tool "$f" > /dev/null; then
    if [ -n "${GITHUB_ACTIONS:-}" ]; then
      echo "::error file=$f::JSON parse error"
    else
      echo "❌ JSON parse error in $f"
    fi
    errors=$((errors+1))
  else
    echo "  OK  $f"
  fi
done
if [ ! -f renovate.json ]; then
  echo "⚠️  renovate.json not found"
fi
if [ "$errors" != "0" ]; then
  echo "❌ $errors JSON file(s) failed validation" >&2
  exit 1
fi
echo "✅ validate-json: OK"
