# ADR-006: Application health for sync-waves and plain Applications for Vault ordering

**Status:** Accepted · **Date:** 2026-08-28

## Context

`gitops/values.yaml` declares a wave-ordered platform stack:

```
wave 0: cert-manager, external-secrets, longhorn
wave 1: vault
wave 2: seaweedfs
wave 3: monitoring
wave 4: tailscale
```

The intent is `vault (1) -> seaweedfs (2)` and by extension `longhorn (0) -> vault (1)`: Vault backs ExternalSecrets and must be healthy before dependents start.

Two gaps broke that intent:

1. **ArgoCD does not ship an `argoproj.io/Application` health check.** `argocd-cm` `resource.customizations` ships Lua for many CRDs (e.g. `ClusterSecretStore`, `Prometheus`) but not for `Application` itself. Without it, a sync-wave considers the Application done as soon as it is `Synced`, even if its workload is still `Progressing`/`Degraded`. Wave `1` therefore did not actually gate wave `2`.

2. **`sync-wave` on `ApplicationSet` templates does not order generated Applications.** `gitops/templates/platform-*.yaml` are `ApplicationSet`s with a `list` generator. The parent `Application` (`gitops`) syncs the `ApplicationSet` objects; the `ApplicationSet` controller then reconciles all `elements` in parallel. `argocd.argoproj.io/sync-wave` on `template.metadata.annotations` is evaluated inside each generated `Application`'s own sync (ordering its Kubernetes resources), not as an ordering between generated `Application`s. All waves were created at once — observed as seaweedfs starting before vault was ready.

This ADR records why we fix both at the contract level rather than papering over with retries.

## Why ArgoCD forces the custom health check (not a default)

ArgoCD intentionally keeps `Application` health generic:

- **Applications are isolation boundaries.** The controller is designed to reconcile thousands of Applications independently. Coupling wave progression to `Application` health by default would make one degraded Application block unrelated waves/clusters — a scalability and blast-radius choice the project defers to operators.
- **Health is user-defined via Lua.** `resource.customizations` is the extension point for every CRD. Upstream ships defaults only for CRDs with a single canonical Ready condition. `Application` health is a composition of `status.health` + `status.sync` + controller-specific conditions, which teams weight differently (some want `Degraded` to block, some want `Progressing` to count as healthy for waves). The project leaves this policy to `argocd-cm` instead of baking one opinion in.
- **Historical compat.** Enabling it globally in the chart would change wave semantics for every existing App-of-Apps on upgrade (previously wave = `Synced`, after = `Synced && Healthy`). Upstream chose opt-in to avoid a silent breaking change — see the long-running `dependsOn` discussion in `argoproj/argo-cd#7437` and the `sync-wave-group` proposal `#25282` which is still alpha and single-Application scoped.

Consequence: any homelab that relies on `App-of-Apps + sync-wave` for cross-Application ordering must declare the `Application` health Lua itself. That is not a workaround — it is the supported contract.

## Options Considered

### Option A — Keep ApplicationSets, add ProgressiveSync (RollingSync)

Add `spec.strategy.type: RollingSync` with wave-partitioned `steps` to both `platform-helm-appset.yaml` and `platform-local-appset.yaml`.

**Pros:** Keeps the DRY `ApplicationSet` generators; ordering is declarative inside the `ApplicationSet` spec; no new templates to maintain.

**Cons:** Adds a Beta feature (`ProgressiveSync` went Beta in ArgoCD v3.5) to the critical bootstrapping path; `strategy` is `ApplicationSet`-specific so plain `Application`s and `ApplicationSet`s now use two different ordering mechanisms; rollback/bisect of a single wave still requires understanding `RollingSync` step matching; couples ordering to label `wave` selectors which are easy to mis-configure.

### Option B — Plain Applications for all wave-ordered platform apps (SELECTED — extended)

Render **every** wave-ordered platform Application as a plain `Application` manifest in `gitops/templates/apps/` with `argocd.argoproj.io/sync-wave` + `wave-policy` label, ordered on disk as `00-*`, `01-*`, etc. The parent `Application` (`gitops`) directly manages them so native sync-waves gate correctly. `ApplicationSet`s (`platform-helm-apps`, `platform-local-apps`) are kept empty as placeholders for future unordered fleet — they no longer drive the ordered core.

Final wave map (ADR-006 as implemented):
```
00: cert-manager, external-secrets, longhorn  (certs + secrets + storage must exist first)
01: vault                                      (needs cert-manager + storage)
02: seaweedfs                                   (needs vault for secrets)
03: monitoring (+ any future wave-3 apps)       (needs vault/external-secrets)
04: tailscale                                   (must be last — exposes everything via tailnet)
```

`wave-policy` label (handled by the `Application` health.lua) allows per-Application opt-out:
- `wave-policy: healthy` (default) — wave gates on `Synced && Healthy`
- `wave-policy: sync-only` — wave gates only on `Synced` (useful if you want a degraded Prometheus not to block tailscale)

**Pros:** Single, GA sync-wave model for the entire platform; file prefix `00-`, `01-` mirrors wave order on disk; deterministic DAG visible in `helm template` and Argo UI; tailscale is guaranteed last; per-app `wave-policy` enables `healthy` vs `sync-only` without a second Lua.

**Cons:** Slight duplication vs generators (one small YAML per app); adding a wave-ordered app requires a new file with correct prefix/wave.

### Option C — Eventual consistency / retries

Rely on `syncPolicy.automated + retry` and let Argo retry until Vault's webhook/secret is available.

**Pros:** Zero templating change.

**Cons:** Non-deterministic; hides ordering failures as `Degraded` retries; does not express the actual dependency graph; makes incident triage harder (which app blocked which?).

## Decision

1. **Declare the `argoproj.io/Application` health check in the infra repo** — `infra-talos-homelab/modules/platform/values/argocd/values.yaml` now includes a `wave-policy` aware Lua:

   ```lua
   -- label wave-policy: healthy (default) = Synced && Healthy
   -- label wave-policy: sync-only        = Synced only
   -- also supports annotation argocd.argoproj.io/wave-policy
   local policy = labels["wave-policy"] or annotations["argocd.argoproj.io/wave-policy"] or "healthy"
   if policy == "sync-only" then
     hs.status = syncStatus == "Synced" and "Healthy" or "Progressing"
   else
     hs.status = (health == "Healthy" and sync == "Synced") and "Healthy" or health == "Degraded" and "Degraded" or "Progressing"
   end
   ```

   This makes sync-waves wait for `Healthy + Synced` by default (Flux `dependsOn` semantics), with an explicit opt-out per app.

2. **Adopt Option B for the entire ordered core.** All wave-ordered platform apps are now plain `Application`s in `gitops/templates/apps/` with `00-`/`01-` prefixes mirroring waves. `ApplicationSet`s remain empty for future unordered fleet. Tailscale is `wave 4` and thus always last — it only syncs after every wave-3 app is `Healthy`.

3. **ProgressiveSync is explicitly not adopted for the critical path** at this time. It remains viable if the fleet grows to many generated Applications, but plain Applications give the required guarantee today without a Beta feature.

## Consequences

- Wave ordering becomes deterministic: `00/*` must be `Synced/Healthy` before `01/vault`, etc.; tailscale `04` only syncs after every `03/*` app is `Healthy`. Pruning reverses the order (`04 -> 00`).
- If any wave fails (`Degraded` or `OutOfSync`), the sync stops at that wave and later waves are NOT applied in that run — next sync retries from the failed wave. This is intentional for the ordered core (like Flux `dependsOn`).
- The infra Terraform root (`platform`) owns the `Application` health policy — a platform concern — consistent with ADR-003/005.
- Adding a new ordered app = add `0N-<name>.yaml` with correct `sync-wave` + `wave-policy` label. Use `sync-only` only for leaf apps where a `Degraded` should not block later waves.
- If upstream ships native `spec.dependsOn` (issues `#7437` / `#25282`), this ADR will be revisited. Until then, `Application health Lua + plain Applications + sync-wave + prefix` is the GA substitute.

## Files

| Action | File |
|--------|------|
| Updated | `infra-talos-homelab/modules/platform/values/argocd/values.yaml` — `argoproj.io/Application` health.lua with `wave-policy` (healthy/sync-only) |
| Updated | `gitops-platform/gitops/values.yaml` + `values-dev.yaml` — `platformApps.helm/local` emptied; waves now live in `templates/apps/` |
| Created | `gitops/templates/apps/00-cert-manager.yaml` (0) · `00-external-secrets.yaml` (0) · `00-longhorn.yaml` (0) |
| Created | `gitops/templates/apps/01-vault.yaml` (1) · `02-seaweedfs.yaml` (2) · `03-monitoring.yaml` (3) · `04-tailscale.yaml` (4) |
| Kept | `gitops/templates/platform-*.yaml` — ApplicationSets with empty `list` (future unordered fleet placeholder) |
| Created | `docs/adrs/006-app-health-and-vault-ordering.md` — this ADR |
