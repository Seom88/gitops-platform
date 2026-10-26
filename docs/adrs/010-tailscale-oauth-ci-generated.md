# ADR-010: Tailscale OAuth — CI-Generated Secret, Two-Chart Wave Split

**Status:** Superseded by current local bootstrap path · **Date:** 2026-08-31 · **Supersedes:** [ADR-004](004-tailscale-oauth-seed-strategy.md) · **Follow-up:** [ADR-011](011-tailscale-dns-np.md) removes `hostNetwork` fallback and scopes DNS via `coredns-patch` + NetworkPolicy (2026-09-01)

> [!NOTE]
> **Addendum (2026-10-26).** `deploy.yaml` was removed; CI never touches the cluster and no GitHub secret is consumed. The only Tailscale credential path is now the local `.env` via `just secrets-apply` / `bootstrap/init-gitops.sh`. The operator also moved to chart `1.104.1` at wave `-2` (`healthy`). The CI-generated design and version pins below are history; the current path is in [`docs/secrets-structure.md`](../secrets-structure.md).

## Context

`platform/tailscale` historically bundled the `tailscale-operator` Helm subchart (`1.102.3`, `https://pkgs.tailscale.com/helmcharts`) together with 11 platform `Ingress` resources and an `ExternalSecret operator-oauth-key` (wave `-1`) that synced `secret/tailscale/auth` (`client_id`/`client_secret`) from Vault via a dedicated `ClusterSecretStore vault-tailscale` (wave `2`) and a seeding `Job vault-config-tailscale` (wave `1`, `ChangeMeSecret` placeholder, per ADR-004 option C — Vault UI clickops).

Three problems converged:

1. **Vault UI clickops for an OAuth secret.** Every fresh cluster or secret rotation required opening Vault UI to write `secret/tailscale/auth` before the operator could authenticate — friction that ADR-004 documented as deliberate but that no longer fits a CI-driven homelab with `tag:cicd` Tailscale OAuth and GitHub Actions as source of truth.
2. **Wave ordering fragility.** `platform/tailscale` was wave `4` (`sync-only`) but internally contained an `ExternalSecret` at wave `-1` and a dependency on `vault-tailscale` at wave `2`. The chart mixed concerns (operator lifecycle vs. ingress exposure) and leaked Helm dependency validation into every `helm template platform/tailscale` that only cared about ingresses.
3. **Velero bucket-init race.** `platform/velero/templates/job-bucket-init.yaml` was a plain wave `-1` `Job` reaching `https://rustfs.lonk-mirfak.ts.net` via Tailscale MagicDNS. If the operator was not yet `Healthy`, the `aws s3api head-bucket` hit an unresolved DNS name and the Job failed. Moving the Job to a Sync hook at wave `0` serializes it *after* the operator is `Healthy` (via `coredns-patch` wave `0` stub), removing the race without `hostNetwork` coupling — see ADR-011.

The homelab is starting from zero VMs (no backward compatibility required), so an atomic, git-revertable cutover is acceptable.

## Options Considered

### Option A — Keep monolithic `platform/tailscale` + Vault ESO (REJECTED)

Keep `Chart.yaml` with `tailscale-operator:1.102.3` dependency, `ExternalSecret operator-oauth-key`, `ClusterSecretStore vault-tailscale`, and `Job vault-config-tailscale` (`ChangeMeSecret` + UI entry).

**Pros:** No migration; ADR-004 already documents the clickops workflow.

**Cons:** Preserves manual Vault UI step; operator lifecycle entangled with 11 ingress definitions; dependency `condition: tailscale-operator` leaks into lint/template of ingress-only consumers; Vault UI remains in the critical path for every `TS_OAUTH_SECRET` rotation; Velero wave `-1` Job remains racy against MagicDNS; contradicts the cluster's CI-driven secret model already used for `cloud-credentials` (Velero) outside Vault.

### Option B — Single chart, dual Argo Applications with `helm.values` override (REJECTED)

Keep one chart `platform/tailscale` but deploy two Argo `Applications`: one at wave `-1` with `helm.values: tailscale-operator.enabled: true` (operator only) and one at wave `4` with `helm.values: tailscale-operator.enabled: false` (ingresses only).

**Pros:** No chart split; reuses existing chart.

**Cons:** Helm dependency validation still fires for every render (chart still *contains* the operator subchart even when disabled); value overrides are unvalidated (`helm lint` does not check `helm.values` in the Application); rollout ordering is implicit (two Apps same path); ESO bridge still present unless separately deleted.

### Option C — Two-chart split: `platform/tailscale-operator` wave `-1` healthy + `platform/tailscale` ingress-only wave `4` sync-only, CI-generated plain Secret (SELECTED)

Split into:

- `platform/tailscale-operator` — wrapper chart `tailscale-operator 1.0.0` (`appVersion 1.96.5`) with Helm dependency `tailscale-operator:1.102.3` (`https://pkgs.tailscale.com/helmcharts`), containing *only* the operator and `Namespace tailscale` (`privileged`). Values under `tailscale-operator:`: `oauthSecretName: operator-oauth`, `operatorConfig.hostname`, `defaultTags: [tag:k8s-operator]`, `proxyConfig.defaultTags`, `oauth.clientID/secret.secretKeyRef` → plain Secret `tailscale/operator-oauth` (`client_id`/`client_secret`). Deployed via `gitops/templates/apps/-1-tailscale-operator.yaml` at `sync-wave: "-1"`, `wave-policy: healthy`, `CreateNamespace=true`.

- `platform/tailscale` — stripped to **ingress-only**: `Chart.yaml` without `dependencies`, `values.yaml`/`values-dev.yaml` without `tailscale-operator:` block (keeps `argocd/vault/grafana/prometheus/longhorn/seaweedfs` toggles + `developmentApp.enabled`). Templates remain `templates/platform/*.yaml` (11 ingresses/services). Deployed via `gitops/templates/apps/04-tailscale.yaml` at `sync-wave: "4"`, `wave-policy: sync-only`, `automated.prune: true`.

- **Vault bridge deletion:** `platform/tailscale/templates/secret-tailscale.yaml` (`ExternalSecret operator-oauth-key`), `platform/vault/templates/eso/cluster-store-tailscale.yaml` (`ClusterSecretStore vault-tailscale` wave `2`), `platform/vault/templates/eso/vault-config-tailscale.yaml` (`Job vault-config-tailscale` wave `1` with `ChangeMeSecret`), plus removal of the `server.networkPolicy.egress` stanza `to: tailscale:8200` in `platform/vault/values.yaml`. No empty placeholders remain.

- **Secret lifecycle:** source of truth is GitHub Secrets `TS_OAUTH_CLIENT_ID` / `TS_OAUTH_SECRET` (Tailscale OAuth client with `tag:cicd`) plus local env fallback `TS_OAUTH_CLIENT_ID` / `TS_OAUTH_SECRET` (and alias `TS_OAUTH_CLIENT_SECRET`). CI `deploy.yaml` (push `main` + `workflow_dispatch`, `concurrency: deploy-main`, `paths-ignore: docs/**, *.md`) runs *after* Tailscale connect + kubeconfig restore: `kubectl create namespace tailscale --dry-run=client -o yaml | kubectl apply -f -` → `kubectl create secret generic operator-oauth -n tailscale --from-literal=client_id --from-literal=client_secret --dry-run=client -o yaml | kubectl apply -f -` → `kubectl rollout restart deployment/tailscale-operator -n tailscale || kubectl rollout restart deployment/operator -n tailscale || true` (rotation auto-restart; starting from zero, no checksum backward compat needed). Local idempotent mirror: `bootstrap/init-gitops.sh:ensureTailscaleCredentials()` (mirrors `ensureVeleroCredentials()`) ensures `ns tailscale` + same Secret idempotently; `--check` warns and exits `0` without mutation.

- **Velero wave serialization:** `platform/velero/templates/job-bucket-init.yaml` refactored from plain wave `-1` `Job` to **`argocd.argoproj.io/hook: Sync`**, `sync-wave: "0"`, `sync-options: Prune=false`, `hook-weight: "-1"` (`helm.sh/hook-weight` retained), `ttlSecondsAfterFinished: 600`, `activeDeadlineSeconds: 600`, `dnsPolicy: ClusterFirst`, `env: AWS_EC2_METADATA_DISABLED=true`, `AWS_S3_ADDRESSING_STYLE=path` (+ `aws configure set default.s3.addressing_style path`), `--no-verify-ssl` preserved, plus 60 s Secret-volume wait and **120 s `nslookup`/`getent hosts` MagicDNS probe** for `rustfs.lonk-mirfak.ts.net` before `aws s3api create-bucket/head-bucket`. Wave `0` hook executes *after* wave `-1` operator Healthy and `coredns-patch` `ts.net:53` stub, guaranteeing `head-bucket velero-homelab` sees MagicDNS (ADR-011).

**Pros:** No Vault UI on bootstrap or rotation; operator Healthy gate blocks waves `0..4` deterministically; ingress chart lints/renders without operator dependency; Vault bridge deleted atomically (git-revert is the rollback); bucket-init serializes after operator Ready + `coredns-patch` `ts.net:53` stub (no `hostNetwork` needed); CI and bootstrap share the same `--dry-run|apply` idempotent primitive; rotation automatically `rollout restart`s the operator.

**Cons:** Operator `Degraded` (bad `client_id`/`secret` or `tag:cicd` mis-scope) blocks *all* subsequent waves `0..4` until the Secret is fixed (mitigated by `deploy.yaml` `kubectl get secret` fast-fail and `--check` warning); `coredns-patch` adds a wave `0` Job that must stay healthy (mitigated by `backoffLimit:3` and reload idempotency); Secret rotation no longer versioned in Vault (intentional — source is CI Secrets).

## Decision

**Option C: two-chart split + CI-generated plain Secret + Velero wave-0 Sync hook.**

Ordering (Argo `sync-wave`):

| Wave | Application(s) | Policy | Notes |
|------|----------------|--------|-------|
| `-1` | `tailscale-operator` (`platform/tailscale-operator`) | `healthy` | Operator must be `Healthy` before anything else; gates `0..4` |
| `0`  | `coredns-patch` (`platform/coredns-patch` `ts.net:53` stub), `longhorn`, `velero` (`platform/velero` + hook `velero-bucket-init`) | `healthy` / `hook: Sync` | `coredns-patch` patches `kube-system/coredns` from `DNSConfig.status.nameserver.ip`; storage + backup; bucket-init hook waits 120 s for MagicDNS after stub (ADR-011) |
| `1`  | `vault` | `healthy` | Depends on Longhorn PVCs |
| `2`  | `seaweedfs` | `healthy` | Internal S3 (unrelated to Velero RustFS) |
| `3`  | `monitoring` | `sync-only` | Tolerates degraded |
| `4`  | `tailscale` (`platform/tailscale`) | `sync-only` | 11 ingresses only; always last, no operator dep |

Secrets matrix after this change:

| Secret | Namespace | Source of truth | Delivery | Vault/ESO? |
|--------|-----------|-----------------|----------|------------|
| `operator-oauth` (`client_id`, `client_secret`) | `tailscale` | GitHub Secrets `TS_OAUTH_*` + local env | `deploy.yaml` `kubectl create secret --dry-run|apply` + `rollout restart` + `bootstrap/init-gitops.sh:ensureTailscaleCredentials()` | **No** — plain `Secret` |
| `cloud-credentials` (`cloud` ini) | `velero` | `VELERO_AWS_*` fallback `AWS_*` | `bootstrap/init-gitops.sh:ensureVeleroCredentials()` + inherited by `deploy.yaml` `Bootstrap` step | **No** — precedent for Velero |

## Consequences

### Positive

- **No clickops.** Fresh cluster from zero: `TS_OAUTH_CLIENT_ID/SECRET` in repo Secrets + `deploy.yaml` push to `main` (or `workflow_dispatch` `prod|dev`) is sufficient; `bootstrap/init-gitops.sh prod` locally also works with env vars. No Vault UI write of `secret/tailscale/auth` ever required.
- **Explicit dependency graph.** Argo wave `-1` healthy gate is declarative; `helm lint`/`helm template` on `platform/tailscale` no longer validates the operator subchart; `platform/tailscale-operator` lints independently with its single dependency `1.102.3`.
- **Velero MagicDNS race eliminated.** Bucket-init as wave-`0` `Sync` hook (`BeforeHookCreation`, `ClusterFirst`, 120 s probe) cannot start before `coredns-patch` `ts.net:53` stub is Healthy; `s3ForcePathStyle: "true"` + `--no-verify-ssl` + `AWS_S3_ADDRESSING_STYLE=path` handled in one place (ADR-011).
- **Rotation without clickops.** Re-applying `TS_OAUTH_SECRET` via `deploy.yaml` or `init-gitops.sh` automatically `kubectl rollout restart` the operator so new `client_secret` is picked up (no stale Secret pod).
- **Atomic deletion.** Vault ESO bridge (`ClusterSecretStore`, `Job`, `ExternalSecret`) and the `tailscale:8200` `NetworkPolicy` egress are deleted; reverse `4→-1` prune order is safe (tested: `git revert` restores them, deleting `Application -1-tailscale-operator` first, then re-seeding Vault if needed).

### Negative

- **Operator is now on the critical path.** Bad OAuth (`client_id`/`secret` typo, `tag:cicd` missing on the Tailscale ACL) → `tailscale-operator` `CrashLoop` → Argo marks `-1-tailscale-operator` `Degraded` and *blocks* waves `0..4` indefinitely. Operators must fix `tailscale/operator-oauth` and `kubectl rollout restart deployment/tailscale-operator -n tailscale`; `deploy.yaml` should surface the Secret existence check soon after connect.
- **No Vault audit trail for this secret.** CI Secrets have no Vault version history; rotation visibility moves to GitHub audit log + `kubectl get secret operator-oauth -n tailscale -o yaml`.
- **No hostNetwork coupling.** `hostNetwork`/`ClusterFirstWithHostNet` fallback removed (ADR-011); `ClusterFirst` + CoreDNS `ts.net:53` stub is the sole path. If `ProxyGroup`/`Connector` CRDs are adopted later, evaluate HA proxy, not host network.

## Migration / Rollout

One PR, net `+125/-121`, < 400 lines. Atomic: all deletes (ESO bridge + ingress dep) land together with the new operator chart and CI/bootstrap Secret creation.

Steps (starting from zero, no backward compat):

1. Add repo Secrets `TS_OAUTH_CLIENT_ID`, `TS_OAUTH_SECRET` (Tailscale OAuth client with `tag:cicd`, `tag:k8s-*` allowed via ACL).
2. Merge this PR.
3. `git push` to `main` (or `workflow_dispatch` `prod`) triggers `deploy.yaml`: Tailscale connect → kubeconfig restore → `kubectl create ns/secret --dry-run|apply` + `rollout restart` → `bootstrap/init-gitops.sh` (ensures same Secret idempotently) → `helm upgrade --install gitops`.
4. Verify: `kubectl -n tailscale get secret operator-oauth -o jsonpath='{.data}'` decodes to `client_id`/`client_secret`; `argocd app get tailscale-operator` is `Healthy`/`Synced` at wave `-1`; `kubectl -n velero logs job/velero-bucket-init` shows `DNS resolved` → `BucketAlreadyOwnedByYou` or `created` → `head-bucket OK`; `kubectl get ingress -A` lists 11 tailscale ingresses at wave `4`.

**Rollback:** `git revert` the merge commit. To restore Vault bridge: `vault kv put secret/tailscale/auth client_id=... client_secret=...` (or restore from Vault backup), `kubectl delete application tailscale-operator -n argocd` (wave `-1`), Argo prunes the operator; next sync recreates `ClusterSecretStore vault-tailscale` + `Job vault-config-tailscale` + `ExternalSecret operator-oauth-key` at their prior waves.

## Risks

- **Degraded operator blocks pipeline** — see Negative above; mitigate with CI `kubectl get secret` preflight and bootstrap `--check` warning.
- **DNS fallback coupling to Talos** — mitigated by wave-`0` healthy gate; `ProxyGroup`/`Connector` should be evaluated once operator `1.102.3` CRDs are `helm show crds | grep ProxyGroup` verified.
- **Rotation requires rollout** — mitigated by `kubectl rollout restart` in both `deploy.yaml` and `bootstrap/init-gitops.sh`; alternatively a `checksum/secret` annotation on the operator `Deployment` pod template could be added if Vault-style auto-reload is desired.

## Files

| Action | File |
|--------|------|
| Created | `platform/tailscale-operator/Chart.yaml` — wrapper `1.0.0` (`appVersion 1.96.5`) dep `tailscale-operator:1.102.3` `https://pkgs.tailscale.com/helmcharts` |
| Created | `platform/tailscale-operator/values.yaml` — `oauthSecretName: operator-oauth`, `operatorConfig.hostname: tailscale-operator`, `defaultTags: [tag:k8s-operator]`, `proxyConfig.defaultTags: tag:k8s`, `oauth.secretKeyRef` → plain Secret |
| Created | `platform/tailscale-operator/values-dev.yaml` — `hostname: dev-tailscale-operator`, `defaultTags: [tag:k8s-operator-dev]` |
| Created | `platform/tailscale-operator/templates/namespace.yaml` — `Namespace tailscale` privileged |
| Created | `gitops/templates/apps/-1-tailscale-operator.yaml` — `Application tailscale-operator` wave `-1` `healthy`, `CreateNamespace=true` (`-1 breaks 00-` comment) |
| Modified | `platform/tailscale/Chart.yaml` — remove `tailscale-operator:1.102.3` dependency block (now ingress-only) |
| Modified | `platform/tailscale/values.yaml` — delete `tailscale-operator:` block (keep `argocd/vault/grafana/prometheus/longhorn/seaweedfs` + `developmentApp`) |
| Modified | `platform/tailscale/values-dev.yaml` — delete `tailscale-operator:` block |
| Deleted | `platform/tailscale/templates/secret-tailscale.yaml` — `ExternalSecret operator-oauth-key` wave `-1` |
| Deleted | `platform/vault/templates/eso/cluster-store-tailscale.yaml` — `ClusterSecretStore vault-tailscale` wave `2` |
| Deleted | `platform/vault/templates/eso/vault-config-tailscale.yaml` — `Job vault-config-tailscale` wave `1` (`ChangeMeSecret`) |
| Modified | `platform/vault/values.yaml` — remove `server.networkPolicy.egress` stanza `to: tailscale:8200` |
| Modified | `gitops/templates/apps/04-tailscale.yaml` — remains wave `4` `sync-only` (ingress-only `path: platform/tailscale`) |
| Modified | `platform/velero/templates/job-bucket-init.yaml` — `hook: Sync` wave `0` `Prune=false` `hook-weight -1` `ttl 600` `dnsPolicy: ClusterFirst` `AWS_S3_ADDRESSING_STYLE=path` `--no-verify-ssl` + 120 s `nslookup` MagicDNS wait (hostNetwork removed, ADR-011) |
| Modified | `bootstrap/init-gitops.sh` — add `ensureTailscaleCredentials()` before `ensureVeleroCredentials()` and `helm upgrade --install gitops`, `--check` warn-only |
| Modified | `.github/workflows/deploy.yaml` — `push: branches:[main]` `paths-ignore: docs/**, *.md` + `workflow_dispatch`, `concurrency: deploy-main`, step `Ensure Tailscale Operator Secret` (`kubectl create ns/secret --dry-run|apply` + `rollout restart`) before `Bootstrap` |
| Modified | `.github/workflows/validate.yaml` — comment `deploy is sole mutating on main push; validate lint/template only` |
| Modified | `docs/secrets-structure.md` — replace Vault `secret/tailscale/auth` + ESO section with CI `TS_OAUTH_*` → `tailscale/operator-oauth` plain Secret, note `bootstrap/init-gitops.sh` + `deploy.yaml` source |
| Modified | `docs/velero.md` — wave table `tailscale-operator -1`, `coredns-patch 0`, `velero 0` hook, `tailscale 4`; bucket-init section updated to Sync hook wave `0` `ClusterFirst` + DNS wait; operator Healthy + `coredns-patch` stub gate serializes MagicDNS (ADR-011) |
| Created | `docs/adrs/010-tailscale-oauth-ci-generated.md` — this ADR (supersedes ADR-004) |

## References

- ADR-004: `docs/adrs/004-tailscale-oauth-seed-strategy.md` — Vault UI placeholder (superseded)
- Deeper Velero flow: `docs/velero.md` — chicken-egg, wave table, bucket-init Spec, verification
- Platform READMEs: `platform/tailscale-operator/` (new), `platform/tailscale/` (now ingress-only), `platform/velero/README.md`
- CI/CD: `docs/ci-cd.md` — `validate.yaml`/`deploy.yaml` quality gates, `just validate`
- Jobs as hooks: `docs/adrs/007-argocd-jobs-as-sync-hooks.md` — `BeforeHookCreation` pattern used for Velero hook
- Vault decentralization: `docs/adrs/002-vault-config-decentralization.md` — `ClusterSecretStore` per-service pattern (tailscale store removed)
- Tailscale operator: https://tailscale.com/kb/1236/kubernetes-operator — `oauthSecretName`, `operatorConfig`, `proxyConfig`
- Tailscale ACL tags: https://tailscale.com/kb/1068/acl-tags — `tag:cicd`, `tag:k8s-operator`, `tag:k8s`
