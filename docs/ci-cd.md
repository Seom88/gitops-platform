# CI / CD

> GitHub Actions, Helm validation, shell linting, and Renovate — how quality is enforced and GitOps stays healthy.

[← Back to README](../README.md) · [Getting Started →](./getting-started.md) · [Architecture →](./features-deep-dive.md)

## Workflows

Both workflows (`ci.yaml`, `deploy.yaml`) live in `.github/workflows/` and are distro-agnostic — no Terraform, no cluster required for validation. `deploy.yaml` is the only workflow that touches the cluster (via Tailscale + kubeconfig from infra state) and delegates all logic to `bootstrap/init-gitops.sh`.

| Workflow | Trigger | Needs cluster | What it does |
|----------|---------|---------------|--------------|
| `ci.yaml` | `push` + `pull_request` + weekly cron (`0 4 * * 1`) + manual | No | Validate job (Helm lint/template, platform lint, shellcheck, YAML/JSON sanity) + security jobs (Trivy images + config, SARIF; fail-closed for pinned images) — one run, one gate signal |
| `deploy.yaml` | `workflow_run` (CI on `main`) + `workflow_dispatch` (manual) | Yes | Gate on CI green → restore kubeconfig from infra state → `bootstrap/init-gitops.sh` |

### `deploy.yaml` — Deploy GitOps (gated auto + manual)

Triggers: `workflow_run` (auto on `CI` completion on `main`, gated by the `gate` job) + `workflow_dispatch` (manual from GitHub UI / `gh`). Concurrency `deploy-main` (`cancel-in-progress: false`), `environment: ${{ inputs.environment || 'prod' }}` (manual) — auto-deploy targets `prod`.

```yaml
# .github/workflows/deploy.yaml — triggers
on:
  workflow_dispatch:
    inputs:
      environment:
        description: Target environment
        type: choice
        options: [prod, dev]
        default: prod
      force_reapply:
        description: Force reapply even if App-of-Apps already exists
        type: boolean
        default: false

permissions:
  contents: read

concurrency:
  group: deploy-${{ github.ref_name }}
  cancel-in-progress: false

env:
  HELM_VERSION: v3.18.4
  S3_ENDPOINT: https://rustfs.lonk-mirfak.ts.net
  S3_BUCKET: terraform-homelab
```

| Job | Runs | What it does |
|-----|------|--------------|
| `gate` | auto (`workflow_run`) + manual | For `push` events: require the latest `CI` run on the head SHA to be `success` (via `gh api`, `actions: read`); skipped for cron events (never deploy on schedule) and manual dispatch (explicit operator action) |
| `deploy` | manual (`workflow_dispatch`) + auto when `gate` passes | Restore kubeconfig from infra S3 state + Tailscale, run `bootstrap/init-gitops.sh` |

**Deploy job** (`runs-on: ubuntu-latest`, `timeout-minutes: 15`, `environment: ${{ inputs.environment || 'prod' }}`):

1. `checkout` secure repo — `actions/checkout@v7` with `persist-credentials: false`
2. `checkout` infra repo — `actions/checkout@v7` with `repository: Seom88/infra-talos-homelab`, `path: infra`, `token: ${{ secrets.GH_PAT || secrets.GITHUB_TOKEN }}`, `persist-credentials: false` (needs `GH_PAT` to read the private infra state repo)
3. `setup-terraform` — `hashicorp/setup-terraform@v4` with `terraform_wrapper: false` (only for `terraform output` to fetch kubeconfig; no apply)
4. `setup-kubectl` — `azure/setup-kubectl@v5`
5. `setup-helm` — `azure/setup-helm@v5` with `version: ${{ env.HELM_VERSION }}` (`v3.18.4`)
6. `install jq / yq` — `jq --version` + `wget mikefarah/yq` if `yq` missing, `yq --version`
7. `tailscale/github-action@v4` with `TS_OAUTH_CLIENT_ID` / `TS_OAUTH_SECRET` (`tags: tag:terraform`, `use-cache: 'true'`) — subnet-route reachability to the cluster (Tailscale mesh, no exposed ports)
8. `restore kubeconfig from infra state` (`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`):
   ```bash
   ENV="${{ inputs.environment || 'prod' }}"
   TF_DIR="infra/environments/proxmox/${ENV}"
   terraform -chdir="$TF_DIR" init -reconfigure -input=false
   terraform -chdir="$TF_DIR" output -raw kubeconfig > /tmp/kubeconfig.yaml
   # fallback if output fails:
   aws s3api get-object --bucket $S3_BUCKET --key "proxmox/${ENV}/terraform.tfstate" \
     --endpoint-url $S3_ENDPOINT /tmp/tfstate.json
   jq -r '.outputs.kubeconfig.value // empty' /tmp/tfstate.json > /tmp/kubeconfig.yaml
   chmod 600 /tmp/kubeconfig.yaml
   echo "KUBECONFIG=/tmp/kubeconfig.yaml" >> "$GITHUB_ENV"
   KUBECONFIG=/tmp/kubeconfig.yaml kubectl cluster-info --request-timeout=10s
   KUBECONFIG=/tmp/kubeconfig.yaml kubectl get nodes --request-timeout=10s
   ```
   Fails fast if `infra/environments/proxmox/${ENV}` is missing or resulting kubeconfig is empty.
  9. `ensure Tailscale operator Secret` — `kubectl create secret generic operator-oauth -n tailscale` from `K8S_TS_OAUTH_*`, then rollout restart of the operator.
  10. `bootstrap (delegates to init-gitops.sh — single source of truth)` (`KUBECONFIG=/tmp/kubeconfig.yaml`):
   ```bash
   ENV="${{ inputs.environment || 'prod' }}"
   FORCE="--force" # only if inputs.force_reapply == true
   chmod +x bootstrap/init-gitops.sh platform/vault/scripts/bootstrap-vault.sh
   ./bootstrap/init-gitops.sh "$ENV" $FORCE
   ```
   `init-gitops.sh` is idempotent: `helm upgrade --install gitops`, Longhorn CSI gate (wave 0), `ensureVeleroCredentials()` (see [Velero](./velero.md)), `bootstrap-vault.sh`, status verifier. See [Getting Started](./getting-started.md).
  11. `cleanup kubeconfig` (`if: always()`) — `shred -u /tmp/kubeconfig.yaml || rm -f /tmp/kubeconfig.yaml /tmp/tfstate.json`

> `deploy.yaml` never runs `terraform apply` — infra is owned by `infra-talos-homelab`. This repo only fetches kubeconfig and delegates to `bootstrap/init-gitops.sh`, which in turn applies the ArgoCD App-of-Apps (`gitops/` chart, wave-ordered).

**Required GitHub secrets:**

| Secret | Required | Value |
|--------|----------|-------|
| `TS_OAUTH_CLIENT_ID` | yes | Tailscale OAuth client ID (`tag:terraform`, scopes `devices:core:write` + `auth_keys:write`) |
| `TS_OAUTH_SECRET` | yes | Tailscale OAuth client secret |
| `GH_PAT` | yes (private infra) | GitHub PAT with `repo` read to `Seom88/infra-talos-homelab` (`checkout infra` step); falls back to `GITHUB_TOKEN` if infra is public |
| `AWS_ACCESS_KEY_ID` | yes | RustFS S3 access key (bucket `terraform-homelab`, path-style, `S3_ENDPOINT`) |
| `AWS_SECRET_ACCESS_KEY` | yes | RustFS S3 secret key |
| `PROXMOX_API_TOKEN` | no | Not used in this repo (infra repo owns Proxmox); listed only if you fork both repos with shared secrets |

To use from a fork, configure `tagOwners` / `acls` for `tag:terraform → tag:pve` in your Tailscale ACL and set `GH_PAT` so the workflow can clone the (private) infra repo. The `S3_ENDPOINT` / `S3_BUCKET` envs point at RustFS (`https://rustfs.lonk-mirfak.ts.net`).

### `ci.yaml` — Validate + Security (fast feedback, no cluster)

Triggers: `push` + `pull_request` (all branches) + weekly cron (`0 4 * * 1`, Mondays 04:00 UTC — images accumulate CVEs without repo changes) + `workflow_dispatch`. Concurrency per workflow ref (`cancel-in-progress: true`). No cluster, no creds. Formerly two workflows (`validate.yaml` + `security.yaml`); merged into one run so each push fires a single CI signal and the deploy gate reads one workflow.

```yaml
# .github/workflows/ci.yaml — triggers
on:
  push:
  pull_request:
  workflow_dispatch:
  schedule:
    - cron: '0 4 * * 1'

permissions:
  contents: read

env:
  HELM_VERSION: v3.18.4

jobs:
  validate:
    runs-on: ubuntu-latest
    timeout-minutes: 10
```

| Step | What it does |
|------|--------------|
| `checkout` | `actions/checkout@v7` `persist-credentials: false` |
| `secret scan` | `detect-secrets-hook --baseline .secrets.baseline` — fail on new secrets, never auto-updates |
| `setup-helm` | `azure/setup-helm@v5` `version: v3.18.4` |
| `helm dependency build (gitops)` | `helm dependency build gitops` (no-op if no deps) |
| `helm dependency build (platform charts)` | `helm repo add` longhorn/grafana/prometheus-community/seaweedfs/tailscale/hashicorp + `helm repo update`; loop `platform/*/` → `helm dependency update/build` |
| `lint gitops (prod)` | `helm lint gitops -f gitops/values.yaml` |
| `lint gitops (dev)` | `helm lint gitops -f gitops/values-dev.yaml` |
| `render gitops (prod) — empty check` | `helm template gitops gitops -f gitops/values.yaml > /tmp/gitops-prod.yaml` + `test -s` + `wc -l` + `grep -c '^---'` + `head -n 80` |
| `render gitops (dev) — empty check` | `helm template gitops gitops -f gitops/values-dev.yaml > /tmp/gitops-dev.yaml` + `test -s` |
| `lint platform charts` | Loop `platform/*/` with `Chart.yaml` → `helm lint "$dir"` (fail aggregated via `failed` flag) |
| `shellcheck` | Install `shellcheck` if missing (`apt-get`); `shellcheck bootstrap/init-gitops.sh` + `shellcheck platform/vault/scripts/bootstrap-vault.sh` |
| `yaml sanity` | `python3` + `yaml.safe_load_all` over `**/*.yaml` skipping `/templates/` `/charts/` `platform/longhorn/charts/` and Go templates (`{{`/`{%`) |
| `json sanity` | `python3 -m json.tool` over `**/*.json` skipping `charts/.git/node_modules`; warn if `renovate.json` missing |
| `yamllint` | `continue-on-error: true` — `pip install yamllint`, `yamllint -c .yamllint.yaml gitops/ platform/ bootstrap/` (templates ignored, `helm lint` owns them) |

Local equivalent: `just validate` (same checks, no creds). Sub-recipes: `just validate-gitops`, `just validate-platform`, `just validate-scripts`, `just validate-yaml`, `just validate-json`.

### Security jobs (in `ci.yaml` — Trivy scans, no cluster)

Same triggers as above (including the weekly cron). Top-level `permissions: contents: read`. No cluster, no creds. The deploy gate requires the single CI run green on the head SHA — one lookup, no fan-in race where the first finisher fails the gate.

| Job | What it does |
|-----|--------------|
| `discover` | Renders every chart (`platform/*/` + `apps/*/`, same repo/dependency prep as Validate, `s3.tailnetFqdn=s3-validate.invalid` for Velero) and collects the unique `image:` refs into a JSON array output (`images`) — no hardcoded list, so Renovate bumps are scanned automatically; a second output (`pinned`) holds the digest-pinned first-party subset that gates fail-closed (matched by repo prefix, so tag/digest bumps keep flowing into the gate). The `image:` matcher also covers `- image:` list-item form (initContainers) |
| `trivy-images` | [`aquasecurity/trivy-action@v0.36.0`](https://github.com/aquasecurity/trivy-action) matrix over `fromJson(needs.discover.outputs.images)` with `scanners: vuln`, `severity: HIGH,CRITICAL`, `ignore-unfixed: true`, and a dynamic `exit-code` (`1` only when the exact ref is in `pinned`; `0` otherwise) — per image a visible `table` scan plus a `sarif` scan uploaded via `github/codeql-action/upload-sarif@v4` (`if: always()`, `category: trivy-<sanitized-name>`). Pinned refs use `continue-on-error: false`; advisory refs still report table and SARIF findings but use `exit 0` and `continue-on-error: true`. The job checks out the repo so Trivy applies `.trivyignore` |
| `trivy-config` | `scan-type: config`, `scan-ref: .` → `trivy-config.sarif` + SARIF upload — complements the PSA restricted policy (v2) |

All jobs run with `permissions: contents: read` + `security-events: write` (least privilege for SARIF upload). Digest-pinned first-party images (homepage, kubectl jobs, velero plugin, aws-cli bucket-init) block the workflow on HIGH/CRITICAL findings outside `.trivyignore`; upstream subchart images are advisory (`continue-on-error: true`) because only upstream releases fix them — they stay pinned transitively via `Chart.lock` and are re-scanned weekly. Image names contain `/` and `:`, so the SARIF filename is derived in bash (`safe=${IMAGE//[:\/]/_}`). A chart that fails to render is skipped with a warning instead of breaking discovery; empty discovery fails loudly rather than passing vacuously. Consciously accepted CVEs go in `.trivyignore` (one per line, with justification and review date).

First-party images are digest-pinned (`tag@sha256:…`, tag kept for Renovate). Upstream subchart images are pinned transitively via `Chart.lock`. Renovate's `github-actions` manager already groups these actions for automatic weekly bumps, and the `kubectl jobs` group (`pinDigests: true`) plus the docker regex managers track the pinned refs.

Local equivalent: `just scan` (same discovery loop + `HIGH,CRITICAL` table summary; soft-fails if `trivy` is not installed — heavy network pulls, deliberately not part of `just validate`).

### Secret scan (`Secret scan` step in the `validate` job of `ci.yaml`)

`detect-secrets-hook --baseline .secrets.baseline` fails the run on any new potential secret; the baseline is never auto-updated (audit locally with `detect-secrets audit .secrets.baseline`). Same hook runs locally via `pre-commit install` — see [Getting Started](./getting-started.md#pre-commit-fast-local-checks).

## Quality gates

| Gate | How | Where |
|------|-----|-------|
| Helm lint | `helm lint gitops -f gitops/values{,-dev}.yaml` + `helm lint platform/*/` | `ci.yaml`, `just validate-gitops`, `just validate-platform` |
| Helm template | `helm template gitops gitops -f gitops/values{,-dev}.yaml` + empty/manifest count check | `ci.yaml`, `just validate-gitops` |
| Helm dependencies | `helm dependency build/update gitops` + `platform/*/` (with `helm repo add` for 6 repos) | `ci.yaml`, `just validate-platform`, `just helm-deps` |
| Shell lint | `shellcheck bootstrap/init-gitops.sh` + `platform/vault/scripts/bootstrap-vault.sh` | `ci.yaml`, `just validate-scripts` |
| YAML syntax | `PyYAML safe_load_all` (Helm templates skipped) + `.yamllint.yaml` | `ci.yaml`, `just validate-yaml` |
| JSON syntax | `python3 -m json.tool` over `**/*.json` | `ci.yaml`, `just validate-json` |
| Inline image convention | No split `repository:` blocks in `values*.yaml` (Renovate-manager-1 invisible) | `ci.yaml` (`validate-images`), `just validate-images`, pre-commit hook |
| Secret scan | `detect-secrets-hook --baseline .secrets.baseline` (fail on new) | `ci.yaml`, `.pre-commit-config.yaml` |
| Image scan | `trivy-action@v0.36.0`, `HIGH,CRITICAL` + SARIF (fail-closed for pinned images, advisory for upstream) | `ci.yaml` (security jobs), `just scan`, `.trivyignore` |
| Config scan | `scan-type: config`, misconfig SARIF | `ci.yaml` (security jobs), `just scan-config` |
| Full local CI | `just validate` (gitops + platform + scripts + yaml + json) + `just validate-images` | `justfile` |
| Hardened inputs | `helm lint` strict, `null` guards in bootstrap, CSI wait gate before Vault | [Getting Started](./getting-started.md), `bootstrap/init-gitops.sh` |

## Justfile

`just` is the local task runner — all CI checks have a local mirror.

| Recipe | What it does |
|--------|--------------|
| `init-prod` | `./bootstrap/init-gitops.sh prod` — full bootstrap (idempotent, status verifier if App-of-Apps exists) |
| `init-prod-force` | `./bootstrap/init-gitops.sh prod --force` — reapply App-of-Apps even if it exists |
| `init-dev` | `./bootstrap/init-gitops.sh dev` — same with `gitops/values-dev.yaml` |
| `init-dev-force` | `./bootstrap/init-gitops.sh dev --force` |
| `vault-init` | `./platform/vault/scripts/bootstrap-vault.sh` — init + unseal only (per-service config via PostSync Jobs) |
| `pf-argocd` | `kubectl port-forward svc/argocd-server -n argocd 8080:443` |
| `pf-vault` | `kubectl port-forward svc/vault -n vault 8200:8200` |
| `pf-prometheus` | `kubectl port-forward svc/prometheus-kube-prometheus-prometheus -n monitoring 9090:9090` |
| `pf-grafana` | `kubectl port-forward svc/prometheus-grafana -n monitoring 3000:80` |
| `argocd-password` | `kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' \| base64 -d` |
| `vault-token` | Derive `vault-unseal-keys` secret name from pod label `app.kubernetes.io/instance` + `kubectl get secret ... -o jsonpath='{.data.root-token}' \| base64 -d` |
| `status` | `kubectl get nodes -o wide` + `kubectl get pods -n argocd/vault/monitoring` |
| `validate` | Runs all local validations (`validate-gitops` + `validate-platform` + `validate-scripts` + `validate-images` + `validate-yaml` + `validate-json`) — mirrors `ci.yaml` validate job |
| `validate-gitops` | `helm dependency build` + `helm lint` prod/dev + `helm template` prod/dev empty check |
| `validate-platform` | `helm repo add` (6 repos) + `helm dependency update/build` + `helm lint` per `platform/*/` |
| `validate-scripts` | `shellcheck bootstrap/init-gitops.sh` + `platform/vault/scripts/bootstrap-vault.sh` (soft-fail if missing) |
| `validate-images` | Fail on split `repository:` + `tag:` blocks in `values*.yaml` (invisible to Renovate Manager 1 — use inline `image:`) — mirrors CI, same pre-commit hook |
| `validate-yaml` | `PyYAML` sanity + `yamllint -c .yamllint.yaml gitops/ platform/ bootstrap/` |
| `validate-json` | `python3 -m json.tool` over `**/*.json` |
| `scan` | Discover images from charts + `trivy image --severity HIGH,CRITICAL` per image (soft-fail if missing; not part of `validate`) |
| `scan-config` | `trivy config` misconfig scan of the repo (soft-fail if missing; not part of `validate`) |
| `sync` | `kubectl apply -n argocd -f gitops/` — force ArgoCD sync (App-of-Apps) |
| `diff` | `helm diff upgrade --install gitops gitops/ -n argocd -f gitops/values.yaml` or `helm template` fallback |
| `docs` | `ls -1 docs/*.md docs/**/*.md` |
| `check` | Verify `kubectl`/`helm`/`git`/`jq` are installed |
| `helm-dry-run` | `helm template` per `platform/*/` + `head -3` |
| `helm-deps` | `helm dependency update` per `platform/*/` + `gitops/` |

## Renovate

`renovate.json` runs weekly **Monday before 05:00 `Europe/Madrid`**, `config:recommended`, labels `dependencies`, ignores `**/charts/*.tgz`:

| Rule | Datasource | Group / Label | Automerge |
|------|------------|---------------|-----------|
| Vault HA Raft + TLS + auto-unseal — wave 1 healthy — needs manual review | `helm` `vault` | `manual-review/vault` | `false` |
| Longhorn storage — needs manual validation (CSI-gated wave 0) | `helm` `longhorn` | `manual-review/longhorn` | `false` |
| cert-manager wave-0 healthy — needs manual review before wave 1 | `helm` `cert-manager` | `manual-review/cert-manager` | `false` |
| Group non-critical Helm charts (loki, kube-prometheus-stack, seaweedfs, tailscale-operator, external-secrets) | `helm` excl. vault/longhorn/cert-manager | `helm charts` (`helm-charts`), `helm` | grouped PR |
| Group GitHub Actions | `github-actions` | `github actions` (`github-actions`), `github-actions` | grouped PR |

Regex managers also cover hardcoded images (`platform/*/templates`, `apps/*/templates`, `apps/*/values*`, Velero initContainers) and `HELM_VERSION` in workflows — so digest-pinned refs (`tag@sha256:…`) keep tag bumps flowing with refreshed digests. Validate Vault/Longhorn/cert-manager upgrades via `just validate` + `helm template` before merging.

## Velero bootstrap

Velero lives outside Vault/ESO (chicken-egg: it backs up Vault). Credentials come primarily from SOPS (`platform/velero/sops/cloud-credentials.enc.yaml`, dedicated keys — see [Velero](./velero.md) and [RustFS IAM](./rustfs-iam.md)), applied by `bootstrap/init-sops.sh`. `bootstrap/init-gitops.sh:ensureVeleroCredentials()` only creates an ephemeral `Secret velero/cloud-credentials` from `AWS_*` when the Secret is missing (reuses the S3 creds already injected by `deploy.yaml`). The chart consumes it via `credentials.existingSecret: cloud-credentials` and a `Job velero-bucket-init` creates the `velero-homelab` bucket idempotently: ArgoCD `Sync` hook at sync-wave `0` with `hook-weight: "-1"`, so it runs first *within* wave `0` (ahead of the chart's own resources, which have no hook-weight) and never blocks itself.

Details, bucket creation, verification, and troubleshooting: **[Velero →](./velero.md)**.

---

Next: [Getting Started →](./getting-started.md) · [Features →](./features-deep-dive.md) · [ADRs →](./adrs/) · [Velero →](./velero.md)
