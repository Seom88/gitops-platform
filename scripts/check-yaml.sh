#!/usr/bin/env bash
# YAML sanity (PyYAML, Helm-template-aware) + best-effort yamllint.
# Shared by CI (ci.yaml validate job) and local `just validate-yaml`.
# NOTE: the yamllint portion is intentionally NON-blocking (warnings only) in
# both contexts — do NOT wrap this step in CI `continue-on-error`, that would
# soften the PyYAML sanity exit 1.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "==> YAML sanity (python yaml)"
python3 - << 'PY'
import glob, sys
try:
    import yaml
except ImportError:
    print("PyYAML not available — skipping")
    sys.exit(0)
errors = 0
for f in glob.glob("**/*.yaml", recursive=True) + glob.glob("**/*.yml", recursive=True):
    # skip Helm templates and vendored charts
    if "/templates/" in f or "/charts/" in f or f.startswith("platform/longhorn/charts/"):
        continue
    with open(f) as fh:
        content = fh.read()
    # skip files with Go templating
    if chr(123)*2 in content or chr(123)+"%" in content:
        continue
    try:
        list(yaml.safe_load_all(content))
    except Exception as e:
        print(f"❌ YAML parse error in {f}: {e}")
        errors += 1
if errors:
    sys.exit(1)
print("   YAML sanity: OK")
PY

# resolve yamllint (brew/pip binary or python module)
YAMLLINT=""
if command -v yamllint >/dev/null 2>&1; then YAMLLINT="yamllint"; elif python3 -m yamllint --help >/dev/null 2>&1; then YAMLLINT="python3 -m yamllint"; fi
if [ -n "$YAMLLINT" ]; then
  echo "==> yamllint gitops/ platform/ bootstrap/ (.yamllint.yaml)"
  $YAMLLINT -c .yamllint.yaml gitops/ platform/ bootstrap/ 2>&1 || echo "⚠️  yamllint reported issues (non-blocking) — see CI SARIF / helm lint for authoritative checks"
else
  echo "   yamllint not installed — skipping (pip install yamllint / brew install yamllint)"
fi
echo "✅ validate-yaml: OK"
