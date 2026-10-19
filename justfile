# ──────────────────────────────────────────────
#  GitOps Platform — ujust / just recipes
# ──────────────────────────────────────────────

# Auto-load .env if present — secrets for k8s (see .env.example)
# .env is gitignored; every recipe inherits K8S_TS_OAUTH_* / AWS_*
set dotenv-load

# ── Default ───────────────────────────────────
_default:
    @just --list

# ── Bootstrap ─────────────────────────────────

# Full bootstrap (production) — idempotent; rerun for status check, --force to reapply
init-prod:
    just secrets-apply
    ./bootstrap/init-gitops.sh prod

# Force reapply App-of-Apps (production)
init-prod-force:
    just secrets-apply
    ./bootstrap/init-gitops.sh prod --force

# Full bootstrap (development mode) — idempotent; rerun for status check, --force to reapply
init-dev:
    just secrets-apply
    ./bootstrap/init-gitops.sh dev

# Force reapply App-of-Apps (development)
init-dev-force:
    just secrets-apply
    ./bootstrap/init-gitops.sh dev --force

# ── Secrets (.env → k8s) ────────────────────────

# Init .env from .env.example (no overwrite)
secrets-init:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ -f .env ]; then
      echo "✅ .env already exists — not overwriting (delete it first to regenerate)"
      exit 0
    fi
    if [ ! -f .env.example ]; then
      echo "❌ .env.example not found" >&2; exit 1
    fi
    cp .env.example .env
    echo "✅ .env created from .env.example — fill in the values, then run: just secrets-apply"

# Check .env vs .env.example — missing keys / empty values / placeholders
secrets-check:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ ! -f .env.example ]; then
      echo "❌ .env.example not found" >&2; exit 1
    fi
    if [ ! -f .env ]; then
      echo "❌ .env not found — create it with: just secrets-init  (or cp .env.example .env)" >&2
      exit 1
    fi
    echo "==> .env vs .env.example"
    missing=0; empty=0; placeholder=0
    while IFS='=' read -r key _; do
      [[ "$key" =~ ^#.*$ || -z "$key" ]] && continue
      key=$(echo "$key" | xargs)
      [ -z "$key" ] && continue
      if ! grep -q "^${key}=" .env; then
        echo "  ❌ missing in .env: $key"; missing=$((missing+1))
      else
        val=$(grep "^${key}=" .env | cut -d'=' -f2-)
        if [ -z "$val" ]; then
          echo "  ⚠️  empty in .env: $key"; empty=$((empty+1))
        elif [ "$val" = "..." ] || [ "$val" = "changeme" ] || [ "$val" = "CHANGEME" ]; then
          echo "  ⚠️  unfilled placeholder in .env: $key=$val"; placeholder=$((placeholder+1))
        fi
      fi
    done < .env.example
    if [ "$missing" = 0 ] && [ "$empty" = 0 ] && [ "$placeholder" = 0 ]; then
      echo "✅ .env OK — all .env.example keys present with values"
    else
      echo ""
      echo "Summary: $missing missing, $empty empty, $placeholder placeholders"
      [ "$missing" != 0 ] && exit 1 || true
      [ "$placeholder" != 0 ] && exit 1 || true
    fi

# Load .env → k8s Secrets (idempotent, re-runnable)
#   tailscale/operator-oauth  via scripts/tailscale-secret.sh (local path — CI holds no cluster credentials)
# velero/cloud-credentials  {cloud: "[default]\\naws_access_key_id=..."} <- AWS_* (SOPS owns dedicated keys; this is fallback only)
secrets-apply:
    #!/usr/bin/env bash
    set -euo pipefail

    # Explicit .env load in case just is invoked with --no-dotenv or outside just
    if [ -f .env ]; then
      set -a; source .env; set +a
    fi
    if [ ! -f .env ]; then
      echo "⚠️  .env not found — using shell / CI env (GitHub Secrets)" >&2
    fi
    # Install secrets
    ./bootstrap/init-sops.sh
    echo "==> secrets-apply (.env → k8s)"

    # ── Tailscale ──────────────────────────────────
    ./scripts/tailscale-secret.sh

    # ── Velero (RustFS S3) ─────────────────────────
    # SOPS owns the dedicated keys (init-sops.sh runs after init-gitops.sh on a
    # bare cluster — the target namespaces must exist first). Imperative
    # creation is fallback only — never overwrite an existing Secret.
    if kubectl get secret cloud-credentials -n velero >/dev/null 2>&1; then
      echo "  🛡️  Velero: Secret velero/cloud-credentials exists (SOPS-managed) — skipping"
    else
      VELERO_ID="${AWS_ACCESS_KEY_ID:-}"
      VELERO_SECRET_VAL="${AWS_SECRET_ACCESS_KEY:-}"
      if [ -z "$VELERO_ID" ] || [ -z "$VELERO_SECRET_VAL" ] || [ "$VELERO_ID" = "..." ] || [ "$VELERO_SECRET_VAL" = "..." ]; then
        echo "  ⏭️  Velero: no valid S3 credentials (AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY) — skipping"
      else
        echo "  🛡️  Velero: creating Secret velero/cloud-credentials (fallback, no SOPS)..."
        kubectl get namespace velero >/dev/null 2>&1 || kubectl create namespace velero >/dev/null 2>&1
        CLOUD_CONTENT="[default]
      aws_access_key_id=${VELERO_ID}
      aws_secret_access_key=${VELERO_SECRET_VAL}"
        kubectl create secret generic cloud-credentials \
          --namespace velero \
          --from-literal=cloud="$CLOUD_CONTENT" \
          --dry-run=client -o yaml | kubectl apply -f - >/dev/null
        echo "  ✅ Velero: Secret velero/cloud-credentials ready"
      fi
    fi

    echo "✅ secrets-apply: done (check with: just secrets-status)"

# k8s Secrets status (values masked)
secrets-status:
    #!/usr/bin/env bash
    set -euo pipefail
    echo "==> k8s Secrets (masked)"
    echo "  tailscale/operator-oauth:"
    if kubectl get secret operator-oauth -n tailscale >/dev/null 2>&1; then
      echo "    ✅ exists — keys: $(kubectl get secret operator-oauth -n tailscale -o jsonpath='{.data}' | tr ',' '\\n' | cut -d'"' -f2 | paste -sd ', ' -)"
      echo "    client_id len: $(kubectl get secret operator-oauth -n tailscale -o jsonpath='{.data.client_id}' | base64 -d | wc -c | xargs) chars"
    else
      echo "    ❌ not found"
    fi
    echo "  velero/cloud-credentials:"
    if kubectl get secret cloud-credentials -n velero >/dev/null 2>&1; then
      echo "    ✅ exists — key 'cloud' present: $(kubectl get secret cloud-credentials -n velero -o jsonpath='{.data.cloud}' | base64 -d | head -1)"
    else
      echo "    ❌ not found"
    fi

# ── Vault ─────────────────────────────────────

# Bootstrap Vault (init + unseal only; per-service config via PostSync Jobs)
vault-init:
    ./platform/vault/scripts/bootstrap-vault.sh

# ── Velero ────────────────────────────────────

# Manual backup from daily-full schedule template (uses values.yaml template, timestamped like scheduled backups)
velero-backup-manual:
    #!/usr/bin/env bash
    set -euo pipefail
    name="manual-velero-daily-full-$(date +%Y%m%d%H%M%S)"
    echo "==> Creating backup $name from schedule velero-daily-full"
    velero backup create "$name" --from-schedule velero-daily-full --wait
    echo "==> $name created — follow with: velero backup describe $name --details"

# ── Port Forwarding ───────────────────────────

# Port-forward ArgoCD UI → localhost:8080
pf-argocd:
    kubectl port-forward svc/argocd-server -n argocd 8080:80

# Port-forward Vault UI → localhost:8200
pf-vault:
    kubectl port-forward svc/vault -n vault 8200:8200

# Port-forward Prometheus → localhost:9090
pf-prometheus:
    kubectl port-forward svc/prometheus-kube-prometheus-prometheus -n monitoring 9090:9090

# Port-forward Grafana → localhost:3000
pf-grafana:
    kubectl port-forward svc/prometheus-grafana -n monitoring 3000:80

# ── Cluster Info ──────────────────────────────

# Show ArgoCD admin password
argocd-password:
    kubectl -n argocd get secret argocd-initial-admin-secret \
      -o jsonpath="{.data.password}" | base64 -d; echo

# Show Vault root token
vault-token:
    #!/usr/bin/env bash
    set -euo pipefail
    # Derive secret name exactly like platform/vault/scripts/bootstrap-vault.sh
    # (RELEASE_NAME from pod label app.kubernetes.io/instance -> <release>-unseal-keys)
    pod=$(kubectl get pod -n vault -l app.kubernetes.io/name=vault,component=server -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")
    if [ -n "$pod" ]; then
      release=$(kubectl get pod "$pod" -n vault -o jsonpath="{.metadata.labels['app\.kubernetes\.io/instance']}" 2>/dev/null || echo "vault")
    else
      release="vault"
    fi
    # Try derived name first, then both known names as fallback
    candidates=("$release-unseal-keys" "vault-unseal-keys" "vault-dev-unseal-keys")
    secret=""
    for c in "${candidates[@]}"; do
      if kubectl get secret "$c" -n vault >/dev/null 2>&1; then
        secret="$c"
        break
      fi
    done
    if [ -z "$secret" ]; then
      echo "No Vault unseal secret found (tried: ${candidates[*]} in namespace vault)" >&2
      echo "Secrets in vault namespace:" >&2
      kubectl get secrets -n vault -o name 2>/dev/null | sed 's/^/  /' >&2 || true
      echo "Debug: kubectl get secret -n vault -l app.kubernetes.io/instance=vault returns:" >&2
      kubectl get secret -n vault -l app.kubernetes.io/instance=vault -o name 2>&1 | sed 's/^/  /' >&2 || true
      exit 1
    fi
    token=$(kubectl get secret "$secret" -n vault -o jsonpath='{.data.root-token}' | base64 -d || true)
    if [ -z "$token" ]; then
      echo "Secret $secret found but .data.root-token is empty/blank" >&2
      kubectl get secret "$secret" -n vault -o jsonpath='{.data}' 2>&1 | sed 's/^/  /' >&2 || true
      exit 1
    fi
    echo "$token"

# Show cluster nodes and versions
status:
    @echo "=== Nodes ===" && \
    kubectl get nodes -o wide && \
    echo "" && \
    echo "=== Platform ===" && \
    kubectl get pods -n argocd -o name && \
    kubectl get pods -n vault -o name 2>/dev/null && \
    kubectl get pods -n monitoring -o name 2>/dev/null

# ── Validate (local — mirrors CI validate job) ──────

# Run all local validations (gitops + platform + scripts + images + yaml + json + kepler-policy)
validate:
    @echo "==> validate: running all checks (gitops + platform + scripts + images + yaml + json + kepler-policy)"
    @just validate-gitops
    @just validate-platform
    @just validate-scripts
    @just validate-images
    @just validate-yaml
    @just validate-json
    @just validate-kepler
    @echo "✅ validate: all checks passed"

# Validate GitOps App-of-Apps chart (lint + render prod/dev)
validate-gitops:
    ./scripts/lint-gitops.sh

# Lint all platform + shared library charts (vault, monitoring, ts-operator, longhorn)
validate-platform:
    ./scripts/lint-charts.sh platform/*/ charts/*/

# ShellCheck bootstrap + scripts/ (soft-fail if not installed)
validate-scripts:
    ./scripts/shellcheck-check.sh

# Enforce inline image convention (no split repository:/tag: in values) — mirrors CI validate job
validate-images:
    ./scripts/check-inline-images.sh

# YAML syntax sanity (PyYAML) + yamllint — skip Helm templates
validate-yaml:
    ./scripts/check-yaml.sh

# JSON syntax sanity (python -m json.tool)
validate-json:
    ./scripts/check-json.sh

# Kepler Cilium policy completeness (apiserver egress, kubelet, probe + scrape ports) — mirrors CI validate job
validate-kepler:
    ./scripts/check-kepler-policy.sh

# ── Security (local — mirrors CI security.yaml; heavy, NOT in validate chain) ─

# Trivy image scan (HIGH,CRITICAL) — local mirror of the CI trivy-images gate (pinned images block); soft-fail if trivy not installed; network pulls, keep out of `validate`
scan:
    ./scripts/scan-images.sh

# Trivy config/misconfig scan (HIGH,CRITICAL, advisory opt-in) — mirrors CI trivy-config; soft-skips without trivy; never in `validate`
scan-config:
    #!/usr/bin/env bash
    set -e
    if ! command -v trivy >/dev/null 2>&1; then
      echo "⚠️  trivy not found — skipping (install with: https://aquasecurity.github.io/trivy/latest/getting-started/installation/)"
      echo "   CI still runs trivy-config in security.yaml; local check is non-blocking"
      exit 0
    fi
    echo "==> scan-config: trivy misconfig scan (HIGH,CRITICAL, advisory — exit 0 either way)"
    if trivy config --help >/dev/null 2>&1; then
      echo "   using 'trivy config' subcommand"
      trivy config --severity HIGH,CRITICAL --ignore-unfixed . || echo "⚠️  scan-config: findings above are advisory (see CI SARIF); not blocking"
    else
      echo "   'trivy config' subcommand missing — using 'trivy fs --scanners misconfig' equivalent"
      trivy fs --scanners misconfig --severity HIGH,CRITICAL --ignore-unfixed . || echo "⚠️  scan-config: findings above are advisory (see CI SARIF); not blocking"
    fi
    echo "✅ scan-config: done (advisory only)"

# ── GitOps ────────────────────────────────────

# Force ArgoCD sync (App of Apps)
sync:
    kubectl apply -n argocd -f gitops/

# Show rendered Helm templates (dry-run)
diff:
    helm diff upgrade --install gitops gitops/ -n argocd -f gitops/values.yaml \
      --set sharedS3.tailnetFqdn=s3-validate.invalid \
      --allow-unreleased 2>/dev/null || \
    helm template gitops gitops/ -n argocd -f gitops/values.yaml \
      --set sharedS3.tailnetFqdn=s3-validate.invalid

# ── Docs ──────────────────────────────────────

# List available documentation
docs:
    @echo "── Documentation ──" && \
    ls -1 docs/*.md docs/**/*.md 2>/dev/null | sed 's/^/  /' || echo "  (no docs found)"

# ── Environment ───────────────────────────────

# Check required tools are installed
check:
    @echo "Checking prerequisites..."
    @kubectl version --client 2>/dev/null && echo "  ✅ kubectl" || echo "  ❌ kubectl — not found"
    @helm version --short 2>/dev/null && echo "  ✅ helm" || echo "  ❌ helm — not found"
    @git --version 2>/dev/null && echo "  ✅ git" || echo "  ❌ git — not found"
    @jq --version 2>/dev/null && echo "  ✅ jq" || echo "  ❌ jq — not found"

# ── Maintenance ───────────────────────────────

# Dry-run Helm upgrades for all platform charts
helm-dry-run:
    #!/usr/bin/env bash
    for chart in platform/*/; do
      name=$(basename "$chart")
      echo "── ${name} ──"
      helm template "$name" "$chart" -n "$name" 2>/dev/null | head -3 || echo "  (skip)"
      echo ""
    done

# Update Helm chart dependencies
helm-deps:
    #!/usr/bin/env bash
    for chart in platform/*/ gitops/; do
      [ -f "${chart}Chart.yaml" ] && helm dependency update "$chart" 2>/dev/null || true
    done
    echo "Dependencies updated."
