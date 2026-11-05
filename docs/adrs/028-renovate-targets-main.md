# ADR-028: Renovate Targets `main` Directly — No `dev` Gate

**Status:** Accepted · **Date:** 2026-11-05 · **Deciders:** Seom88 · **Related:** [ADR-016](016-two-node-prod-trial.md), [ADR-019](019-single-node-bare-metal-migration.md), [ADR-026](026-devcontainer-ai-agents.md)

> **Outcome:** `renovate.json` moves `baseBranchPatterns` from `dev` to `main`. Minor/patch updates (docker images, helm charts, GitHub Actions, regex managers) and docker digest bumps on already-pinned refs automerge straight to `main` after CI green + `minimumReleaseAge` (3 days, null for digests). Majors keep their PRs and never automerge — they are the only human gate. The `dev` branch is dormant, not deleted.

## Context

Renovate has always opened its PRs against `dev`, with patch/minor set to `automerge: true` (3 days). The operator then carried a second, purely mechanical step by hand: merge the Renovate PR into `dev`, then open and approve a promotion PR `dev` → `main`. This was never a safety gate, and the reasons are structural, not personal discipline:

- **There is no dev environment.** No dev k3s node exists ([ADR-019](019-single-node-bare-metal-migration.md)); the `dev` branch deploys nowhere. Dev could not validate an image — it could only lint it, which `main`'s CI does identically on the PR.
- **`main` and ArgoCD are the prod path regardless.** Once anything reaches `main`, ArgoCD pull-deploys it (root app, automated + prune + selfHeal). The dev→main hop never stopped a bad deploy after CI; it only deferred it by one click.
- **Half of what "dev validation" was supposed to prove was already unproven at merge time.** ArgoCD does not wait for CI on `main`; the only real gates anywhere in this repo are CI (lint/render/secret-scan), `minimumReleaseAge`, and the human review of majors.

The recurring cost was real: every promotion was one PR + one approve + one merge of pure ceremony, and the `dev` branch accumulated images that never shipped anywhere.

## Decision

### 1. `baseBranchPatterns: ["main"]`

Renovate now opens PRs against `main`. All other `packageRules` are unchanged except:

- The "automerge patch+minor" rule is reworded (it targeted `dev` promotion semantics).
- New rule: `matchDatasources: ["docker"]`, `matchUpdateTypes: ["digest"]` → `automerge: true`. Digest bumps on already-pinned refs (`tag@sha256:…` → new bits for a fixed tag) are the CVE-fix flow for first-party images; they never carried a semver signal and therefore never matched the patch/minor rule. `minimumReleaseAge` stays `null` via the existing digest rule (`timestamp-required` would stall them forever — Docker Hub 403s paginated `/tags`). Postgres overrides both (`automerge: false`, every bump restarts the DB pods).

Helm minor/patch already automerged under the patch/minor rule (it does not filter by datasource), so charts — vault/longhorn/cert-manager included — flow unchanged; stay aware there are no per-chart automerge exclusions in the file. If one burns, pin it with one `matchPackageNames` + `automerge: false` entry or revert the commit.

### 2. Majors stay manual

`matchUpdateTypes: ["major"]` → `automerge: false` — unchanged, on `main` now. A major PR is opened against `main` and sits until the operator reads it and merges. This is deliberately the only human action left in the routine dependency path.

### 3. `dev` goes dormant, not away

The `dev` branch, `gitops/values-dev.yaml`, `just init-dev` and the `developmentApp.enabled` flag are kept — the design for a future dev cluster (hardware permitting) is unchanged. Renovate simply stops targeting `dev`. `docs/ci-cd.md`'s Renovate table is corrected in the same change (it still advertised `manual-review/vault|longhorn|cert-manager` rules that no longer exist in the file).

### 4. GitHub-side settings required (operator action)

For automerge to actually land without clicks, the `main` branch needs:

- **Allow auto-merge** (repo Settings → General → Pull Requests).
- **Required status check `validate`** (the `CI` workflow's only job) on `main` — Renovate's automerge waits for it.
- **No required approving review.** Renovate cannot approve its own PRs; a 1-review rule would silently re-introduce the click ritual this ADR removes. Majors are protected by `automerge: false`, not by the review rule (see Consequences).
- ArgoCD pull-deploys `main` on merge regardless — CI green is not a barrier to sync, so the required check protects only the merge step.

## Consequences

Positive:

- The routine minor/patch/digest path is fully unattended: Renovate → CI → automerge → ArgoCD → prod. No promotion PR, no manual approve.
- CVE exposure for digest-pinned refs closes automatically (weekly run + digest automerge), which is the Trivy-driven goal behind this change.
- One less branch to keep in sync; promotion merges (and their image-line conflicts) cease to exist.

Negative:

- **A bad minor/patch merges and deploys to prod unattended.** There is no staging to absorb it; the safety net is CI + 3-day `minimumReleaseAge` + `git revert`. Accepted consciously for a homelab (single node, Postgres kept manual, majors manual).
- **No review requirement on `main`** means the major-PR discipline rests on `automerge: false` alone (Renovate will not touch them). Do not re-enable a "required approvals: 1" rule without also bypassing it for Renovate, or the minor/patch path stalls again.
- `dev` can drift unmerged indefinitely (it is archived in practice); anyone later resurrecting a dev cluster must reconcile it against `main` first.

Re-entry conditions — revisit this ADR if:

- Hardware appears for a dev k3s node → retarget `baseBranchPatterns` to `dev` and restore a promotion ADR.
- A minor/patch bump breaks prod more than once → add a `minimumReleaseAge` longer than 3 days or restore a review rule with a Renovate bypass.
- Renovate gains per-packageRule base branches → the original split proposal (minor/patch → main, majors → dev) becomes mechanically possible; evaluated and rejected here in favor of the simpler single-target design.
