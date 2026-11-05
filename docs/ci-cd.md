# CI / CD

> GitHub Actions, Helm validation, shell linting, and Renovate — how quality is enforced and GitOps stays healthy.

[← Back to README](../README.md) · [Getting Started →](./getting-started.md) · [Architecture →](./features-deep-dive.md)

## Workflows

The only workflow is `ci.yaml` (`.github/workflows/`) and it is distro-agnostic — no Terraform, no cluster, no credentials, no Tailscale. **CI never touches the cluster.** All deploys happen through GitOps: commit to `main`, ArgoCD pulls, done (see the [deploy model](#deploy-model--argocd-pull-only) below).

> ### Deploy model — GitOps pull-only
>
> The former `deploy.yaml` workflow (CI-connected deploys with a `KUBECONFIG_DATA` Environment secret) was **removed**. Reasons, verified against the repo:
>
> - The root `gitops` Application is self-managing (`root-prod-app.yaml`: `syncPolicy.automated` with `prune` + `selfHeal`, `targetRevision: main`) — every commit to `main` syncs without a push step.
> - The CI-side "gate on green CI" never actually gated ArgoCD: ArgoCD syncs `main` regardless of Actions state. It only sequenced CI's own mutations.
> - The `helm upgrade --install gitops` in CI duplicated what ArgoCD's automated sync already does.
> - Holding the full `k3s.yaml` (commit-level `cluster-admin` client cert) as a GitHub secret gave GitHub total cluster power for one workflow's benefit. Risk > value.
>
> What CI does **not** replace automatically:
>
> - **Secret seeding / rotation** (`just secrets-apply`): SOPS-encrypted secrets and the Tailscale operator OAuth secret are applied from local `.env`, not from GitHub secrets.
> - **First-sync ordering**: a newly added app that needs a seeded secret may sync (and go Pending) before the secret exists — run `just secrets-apply` right after adding it.
>
> | Removed | State |
> |---------|-------|
> | `.github/workflows/deploy.yaml` (gate + deploy jobs) | Deleted — GitOps pull covers deploys |
> | `KUBECONFIG_DATA` Environment secret | Delete it in GitHub (`Environments → prod/dev → secrets`) — admin cert should never live in a CI system |
> | `TS_OAUTH_*` / `K8S_TS_OAUTH_*` / `AWS_*` repo secrets for deploys | No longer consumed by CI — local `.env` is the single credential source (operator OAuth is still consumed by `just secrets-apply`, Velero fallback by `init-gitops.sh`) |
> | `concurrency: deploy-main` / gate logic | Removed with the workflow |
> | `force_reapply` dispatch flag | Replaced by `just init-prod-force` |
>
> GitHub Actions credentials: **none**. The attack surface shrinks accordingly: a compromised Actions environment can no longer reach the API server.

| Workflow | Trigger | Needs cluster | What it does |
|----------|---------|---------------|--------------|
| `ci.yaml` | `push` + `pull_request` + weekly cron (`0 4 * * 1`) + manual | No | Validate job (Helm lint/template, platform lint, shellcheck, YAML/JSON sanity) + security jobs (Trivy images + config, SARIF; fail-closed for pinned images) — one run, one gate signal |

## Deploy model — GitOps pull-only

`git push` is the only deploy act. No workflow installs, syncs, or touches the cluster.

```
commit → push main → CI validates (no cluster) → ArgoCD auto-sync (root gitops app,
automated + prune + selfHeal, targetRevision main) → wave-ordered platform/app sync
```

### Cluster credentials for the operator (you)

Two kubeconfig options, both valid at any time:

| Option | How | Identity |
|--------|-----|----------|
| Direct node (existing) | Local `k3s.yaml` admin kubeconfig → `https://100.64.0.12:6443` | k3s admin client cert — full power |
| Tailscale API server proxy | `tailscale configure kubeconfig beth` (operator MagicDNS name, auth mode — `apiServerProxyConfig.mode` already enabled) | The proxy impersonates **your Tailscale user**; no k8s credential is stored — RBAC applies via `platform/ts-operator/templates/users/clusterrolebinding-tailnet-admins.yaml` (group `tailnet-admins` → `cluster-admin`) |

Naming scheme (googology): nodes follow the aleph-cardinal series (`aleph-*`); the operator/API-gate device is **`beth` (prod)** / **`beth-dev` (dev)** — `platform/ts-operator/values.yaml:hostname`. Renaming changes the operator's MagicDNS name (the old device may linger in the Tailscale admin console — remove it there; ArgoCD/hubble Ingress MagicDNS names are unaffected).

### Break-glass bootstrap & operations (local, admin kubeconfig)

One-time bootstrap and any repair richer than Argo's self-heal need the admin kubeconfig — deliberately **never** a GitHub secret:

1. `just secrets-apply` — SOPS + operator OAuth + Velero fallback from `.env` (single credential source, gitignored).
2. Install ArgoCD itself (prerequisite — ArgoCD bootstrap owns it, not this repo's charts).
3. `just init-prod` → `./bootstrap/init-gitops.sh prod` — ensures credentials, installs the App-of-Apps, wave-0 Longhorn CSI gate, status checks. Idempotent; rerun to verify status. For dev: `just init-dev` (`values-dev.yaml`, targetRevision `dev` branch).
4. `bootstrap/init-sops.sh` runs inside `just secrets-apply`; on a bare cluster it seeds namespaces + decrypted secrets.

For forks: nothing cluster-side to configure. The only GitHub-side assets remain the repo vars consumed by CI (none cluster-related) and — once Vault returns with the external-secrets recovery system — secret seeding moves in-cluster and the SOPS story ends (see ADR-017, Vault paused not deleted).

### What replaced CI query actions

| Former deploy.yaml behavior | Now |
|-----------------------------|-----|
| `force_reapply` manual dispatch | `just init-prod-force` |
| CI status/diagnostics run | `just init-prod` (idempotent rerun) or `just status-cluster` |
| Auto-apply on secret rotation | `just secrets-apply` (reapplies + rollout-restarts the operator — see `scripts/tailscale-secret.sh`) |
| Tailnet connectivity from runners | Gone — runners never join the tailnet; `tag:cicd` releases can be reclaimed in the Tailscale admin console |

### `ci.yaml` — Validate + Security (fast feedback, no cluster)

Triggers: `push` + `pull_request` (all branches) + weekly cron (`0 4 * * 1`, Mondays 04:00 UTC — images accumulate CVEs without repo changes) + `workflow_dispatch`. Concurrency per workflow ref (`cancel-in-progress: true`). No cluster, no creds. Formerly two workflows (`validate.yaml` + `security.yaml`); merged into one run so each push fires a single CI signal.

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
  HELM_VERSION: v4.3.1

jobs:
  validate:
    runs-on: ubuntu-latest
    timeout-minutes: 10
```

| Step | What it does |
|------|--------------|
| `checkout` | `actions/checkout@v7` `persist-credentials: false` |
| `secret scan` | `detect-secrets-hook --baseline .secrets.baseline` — fail on new secrets, never auto-updates |
| `setup-helm` | `azure/setup-helm@v5` `version: v4.3.1` |
| `helm dependency build (gitops)` | `helm dependency build gitops` (no-op if no deps) |
| `helm dependency build (platform charts)` | `helm repo add` longhorn/grafana/prometheus-community/tailscale/hashicorp + `helm repo update`; loop `platform/*/` → `helm dependency update/build` |
| `lint gitops (prod)` | `helm lint gitops -f gitops/values.yaml` |
| `lint gitops (dev)` | `helm lint gitops -f gitops/values-dev.yaml` |
| `render gitops (prod) — empty check` | `helm template gitops gitops -f gitops/values.yaml > /tmp/gitops-prod.yaml` + `test -s` + `wc -l` + `grep -c '^---'` + `head -n 80` |
| `render gitops (dev) — empty check` | `helm template gitops gitops -f gitops/values-dev.yaml > /tmp/gitops-dev.yaml` + `test -s` |
| `lint platform charts` | Loop `platform/*/` with `Chart.yaml` → `helm lint "$dir"` (fail aggregated via `failed` flag) |
| `shellcheck` | Install `shellcheck` if missing, then `./scripts/shellcheck-check.sh` — all bootstrap and `scripts/` files |
| `yaml sanity` | `python3` + `yaml.safe_load_all` over `**/*.yaml` skipping `/templates/` `/charts/` `platform/longhorn/charts/` and Go templates (`{{`/`{%`) |
| `json sanity` | `python3 -m json.tool` over `**/*.json` skipping `charts/.git/node_modules`; warn if `renovate.json` missing |
| `yamllint` | `continue-on-error: true` — `pip install yamllint`, `yamllint -c .yamllint.yaml gitops/ platform/ bootstrap/` (templates ignored, `helm lint` owns them) |

Local equivalent: `just validate` (same checks, no creds). Sub-recipes: `just validate-gitops`, `just validate-platform`, `just validate-scripts`, `just validate-yaml`, `just validate-json`.

### Security jobs (in `ci.yaml` — Trivy scans, no cluster)

Same triggers as above (including the weekly cron). Top-level `permissions: contents: read`. No cluster, no creds.

| Job | What it does |
|-----|--------------|
| `discover` | Renders every chart (`platform/*/` + `apps/*/`, same repo/dependency prep as Validate, `s3.tailnetFqdn=s3-validate.invalid` for Velero) and collects the unique `image:`/`imageName:` refs into a JSON array output (`images`) — no hardcoded list, so Renovate bumps are scanned automatically; a second output (`pinned`) holds the digest-pinned first-party subset that gates fail-closed (matched by repo prefix, so tag/digest bumps keep flowing into the gate). The `image:` matcher also covers `- image:` list-item form (initContainers) and `imageName:` (CNPG Postgres images). The source grep additionally parses one-line inline maps (`image: { repository: X, tag: T })` so charts that cannot render in CI still contribute their values-declared images — those entries may duplicate their rendered counterpart (e.g. `library/nextcloud` alongside `docker.io/library/nextcloud`); Trivy resolves both to the same image |
| `trivy-images` | [`aquasecurity/trivy-action@v0.36.0`](https://github.com/aquasecurity/trivy-action) matrix over `fromJson(needs.discover.outputs.images)` with `scanners: vuln`, `severity: HIGH,CRITICAL`, `ignore-unfixed: true`, and a dynamic `exit-code` (`1` only when the exact ref is in `pinned`; `0` otherwise) — per image a visible `table` scan plus a `sarif` scan uploaded via `github/codeql-action/upload-sarif@v4` (`if: always()`, `category: trivy-<sanitized-name>`). Pinned refs use `continue-on-error: false`; advisory refs still report table and SARIF findings but use `exit 0` and `continue-on-error: true`. The job checks out the repo so Trivy applies `.trivyignore` |
| `trivy-config` | `scan-type: config`, `scan-ref: .` → `trivy-config.sarif` + SARIF upload — complements the PSA restricted policy (v2) |

All jobs run with `permissions: contents: read` + `security-events: write` (least privilege for SARIF upload). Digest-pinned first-party images (homepage, kubectl jobs, velero plugin, aws-cli bucket-init, nextcloud app — digest travels inside the tag) block the workflow on HIGH/CRITICAL findings outside `.trivyignore`; upstream subchart images are advisory (`continue-on-error: true`) because only upstream releases fix them — they stay pinned transitively via `Chart.lock` and are re-scanned weekly. Image names contain `/` and `:`, so the SARIF filename is derived in bash (`safe=${IMAGE//[:\/]/_}`). A chart that fails to render is skipped with a warning instead of breaking discovery; empty discovery fails loudly rather than passing vacuously. Consciously accepted CVEs go in `.trivyignore` (one per line, with justification and review date).

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
| Vault Raft + TLS + auto-unseal — wave 1, paused/disabled by default — needs manual review | `helm` `vault` | `manual-review/vault` | `false` |
| Longhorn storage — needs manual validation (CSI-gated wave 0) | `helm` `longhorn` | `manual-review/longhorn` | `false` |
| cert-manager wave-0 healthy — needs manual review before wave 1 | `helm` `cert-manager` | `manual-review/cert-manager` | `false` |
| Group non-critical Helm charts (loki, kube-prometheus-stack, tailscale-operator, external-secrets) | `helm` excl. vault/longhorn/cert-manager | `helm charts` (`helm-charts`), `helm` | grouped PR |
| Group GitHub Actions | `github-actions` | `github actions` (`github-actions`), `github-actions` | grouped PR |

Regex managers cover hardcoded `image:` lines (`platform/*/templates`, `apps/*/templates`, `apps/*/values*`, Velero initContainers), CNPG `imageName:` Postgres images, and `HELM_VERSION` in workflows — so digest-pinned refs (`tag@sha256:…`) keep tag bumps flowing with refreshed digests. Inline one-line maps (`image: { repository: X, tag: T }` in nextcloud/immich values) are owned by Renovate's built-in `helm-values` manager: adding a regex manager for the same lines double-extracts the dep and breaks branch creation (seen as `Error updating branch: update failure` on the `library/nextcloud` digest branch). `digest`/`pinDigest` updates run with `minimumReleaseAge: null` (Docker Hub rate-limited `/tags` listings leave no `releaseTimestamp`, which would hold them forever under `timestamp-required`). Postgres image bumps are never auto-merged — every `imageName` change restarts the DB pods. Validate Vault/Longhorn/cert-manager upgrades via `just validate` + `helm template` before merging.

## Velero bootstrap

Velero lives outside Vault/ESO (chicken-egg: it backs up Vault). Credentials come primarily from SOPS (`platform/velero/sops/cloud-credentials.enc.yaml`, dedicated keys — see [Velero](./cluster-recovery.md) and [RustFS IAM](./rustfs-iam.md)), applied by `bootstrap/init-sops.sh`. `bootstrap/init-gitops.sh:ensureVeleroCredentials()` only creates an ephemeral `Secret velero/cloud-credentials` from `AWS_*` when the Secret is missing (`.env` / shell env — the same S3 creds used for the SOPS age-key fetch). The chart consumes it via `credentials.existingSecret: cloud-credentials` and a `Job velero-bucket-init` creates the `velero-homelab` bucket idempotently: ArgoCD `Sync` hook at sync-wave `0` with `hook-weight: "-1"`, so it runs first *within* wave `0` (ahead of the chart's own resources, which have no hook-weight) and never blocks itself.

Details, bucket creation, verification, and troubleshooting: **[Velero →](./cluster-recovery.md)**.

---

Next: [Getting Started →](./getting-started.md) · [Features →](./features-deep-dive.md) · [ADRs →](./adrs/) · [Velero →](./cluster-recovery.md)
