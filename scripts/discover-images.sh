#!/usr/bin/env bash
# Discover runtime images from charts + repo source grep; emit JSON lists.
# Usage: discover-images.sh <out-dir>   (requires exactly one argument)
# Writes: <out-dir>/images.json, <out-dir>/pinned.json
# Fails closed when no images or no digest-pinned images are derived.
# Shared by CI (ci.yaml discover job — CI only adds the GITHUB_OUTPUT echo)
# and the local trivy scan (scripts/scan-images.sh).
set -euo pipefail
cd "$(dirname "$0")/.."
# shellcheck source=helm-repos.sh
source "$(dirname "$0")/helm-repos.sh"

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <out-dir>" >&2
  exit 1
fi
out_dir="$1"
mkdir -p "$out_dir"

helm_repos_ensure

imglist="$(mktemp)"
trap 'rm -f "$imglist"' EXIT
for dir in platform/*/ apps/*/; do
  if [ ! -f "${dir}Chart.yaml" ]; then continue; fi
  name="$(basename "$dir")"
  helm dependency update "$dir" >/dev/null 2>&1 || helm dependency build "$dir" >/dev/null 2>&1 || true
  # Velero and ts-operator require s3.tailnetFqdn (CI-supplied) — render with a test value.
  extra=""
  if [ "$dir" = "platform/velero/" ] || [ "$dir" = "platform/ts-operator/" ]; then
    extra="--set s3.tailnetFqdn=s3-validate.invalid"
  fi
  # shellcheck disable=SC2086
  if ! rendered="$(helm template "$name" "$dir" $extra 2>/dev/null)"; then
    echo "⚠️  discover-images: could not render $dir — skipping (chart needs cluster values)"
    continue
  fi
  printf '%s\n' "$rendered" | awk '/^[[:space:]]*(-[[:space:]]+)?image:[[:space:]]/ && !/\{\{/ {sub(/^[[:space:]]*(-[[:space:]]+)?image:[[:space:]]+/, ""); gsub(/^"|"$|^[ \t]+|[ \t]+$/, ""); if ($0 != "") print}' >> "$imglist" || true
done

python3 - "$imglist" "$out_dir" << 'PY'
import json, os, re, sys
rendered_path, out_dir = sys.argv[1], sys.argv[2]
rendered = set()
with open(rendered_path) as fh:
    for line in fh:
        line = line.strip()
        if line:
            rendered.add(line)
inline_re = re.compile(r'^\s*(?:-\s+)?image:\s*["\']?([^"\'\s{}]+:[^"\'\s{}]+(?:@sha256:[a-fA-F0-9]+)?)["\']?\s*(?:#.*)?$')
repo_re = re.compile(r'^\s*repo:\s*["\']?([^"\'\s{};]+)["\']?\s*(?:#.*)?$')
tag_re = re.compile(r'^\s*tag:\s*["\']?([^"\'\s{};]+)["\']?\s*(?:#.*)?$')
source = set()
for root in ("platform", "apps"):
    for dirpath, dirnames, filenames in os.walk(root):
        # Vendored upstream charts are scanned via their rendered
        # output, not their raw values (their image knobs differ).
        dirnames[:] = [d for d in dirnames if d != "charts"]
        for fn in filenames:
            if not (fn.endswith(".yaml") or fn.endswith(".yml")):
                continue
            if ".enc." in fn:
                continue
            p = os.path.join(dirpath, fn)
            with open(p, errors="replace") as fh:
                lines = fh.read().splitlines()
            for line in lines:
                if "{{" in line or "{%" in line:
                    continue
                m = inline_re.match(line)
                if m:
                    source.add(m.group(1))
            # Split repo:/tag: pairs (e.g. Tailscale DNSConfig
            # nameserver image) joined back into repo:tag refs.
            for i, line in enumerate(lines):
                if "{{" in line or "{%" in line:
                    continue
                m = repo_re.match(line)
                if m:
                    for nxt in lines[i + 1:i + 4]:
                        t = tag_re.match(nxt)
                        if t:
                            source.add(f"{m.group(1)}:{t.group(1)}")
                            break
images = sorted(rendered | source)
# Fail-closed blocking set: digest-pinned images authored in this
# repo (the source-grep set above), never a hardcoded family list,
# so Renovate bumps keep flowing into the blocking gate and a
# renamed/new family can never silently fall through to
# advisory-only. Rendered-only upstream images (e.g. digest pins
# authored by upstream charts) are scanned but stay advisory —
# their CVEs can only be fixed by upstream releases.
pinned = sorted(i for i in source if "@sha256:" in i)
if not images:
    print("::error::no images discovered from charts or source grep")
    sys.exit(1)
if not pinned:
    print("::error::no digest-pinned images derived — blocking gate would be empty, failing closed")
    sys.exit(1)
print(f"Discovered: {json.dumps(images)}")
print(f"Pinned (fail-closed): {json.dumps(pinned)}")
with open(os.path.join(out_dir, "images.json"), "w") as fh:
    json.dump(images, fh)
with open(os.path.join(out_dir, "pinned.json"), "w") as fh:
    json.dump(pinned, fh)
PY
