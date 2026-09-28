# ADR-017: Pause Vault — SOPS + Age as Default for Velocity

**Status:** Accepted · **Date:** 2026-09-20 · **Deciders:** Seom88 · **Related:** [ADR-002](002-vault-config-decentralization.md), [ADR-009](009-vault-dr-and-velero-backup.md)

Vault is paused, not deleted. SOPS + age is the default secrets path until velocity allows a Vault return.

## Context

Vault HA with Raft, TLS, autounseal, bootstrap Job, and per-service ESO `ClusterSecretStore` (ADR-002, ADR-009) is production-grade. It is also expensive per feature: every new secret touches policy + role + seed Job + `ClusterSecretStore` + `ExternalSecret`, plus raft, unseal, and backup concerns.

The last required Vault change made the cost explicit: migrate unseal keys to S3, add a raft-snapshot CronJob for backups, and auto-restore in `bootstrap-vault` — several repo changes across `platform/vault/`, bootstrap, and CI. That work is valuable but not scheduled today, and more app secrets (SeaweedFS, Loki, Grafana, homepage) need to land now.

Decision: freeze `platform/vault/` in place, disable Vault/ESO via flags, and ship new secrets with SOPS + age.

## Decision

1. **Pause, do not delete.** `platform/vault/` stays frozen in `main`. The ArgoCD Applications are gated:
   - `gitops/templates/platform/01-vault.yaml` → `{{ if and .Values.platformApps.enabled .Values.vault.enabled }}`
   - `gitops/templates/platform/00-external-secrets.yaml` → `{{ if and .Values.platformApps.enabled .Values.eso.enabled }}`
   - `gitops/values.yaml` + `gitops/values-dev.yaml` → `vault.enabled: false`, `eso.enabled: false` (default off in both envs).
   - Re-entry is a flag flip + `raft snapshot restore` from the frozen archive, per the golden rule in [ADR-009](009-vault-dr-and-velero-backup.md) §Decision 1. (The runbook that used to document it was deleted 2026-09-28 — see that ADR's addendum.) No long-lived diverge branch.

2. **SOPS + age is the default** for all app and platform secrets. Encrypted files (`*.enc.yaml`) live in git under `<chart>/sops/` (never inside `templates/`, enforced by `init-sops.sh`). Recipients in `.sops.yaml` (`platform/*/sops/*.enc.yaml` → single age recipient).

3. **One external key store.** The age private key lives outside the cluster at `s3://secrets-homelab/sops/keys.txt` (RustFS, same host family as `sharedS3.tailnetFqdn`) plus one offline copy (USB / password manager). S3 holds only bootstrap roots (age key, S3 bootstrap creds, frozen Vault archive) — never live plaintext app secrets.

4. **Bootstrap and CI auto-restore.** `bootstrap/init-sops.sh` (idempotent): pulls `keys.txt` from RustFS via `aws s3 cp` (`--endpoint-url $S3_ENDPOINT --no-verify-ssl`), rejects `*.enc.yaml` inside `templates/`, runs `sops decrypt | kubectl apply` for every `<chart>/sops/*.enc.yaml`, then `shred -u` the key file. Wired into `just secrets-apply` and `.github/workflows/deploy.yaml` (installs `sops v3.10.2`, then restores + applies before `init-gitops.sh`).

5. **Re-entry condition.** Vault returns when dynamic secrets, auto-rotation, or audit become requirements. Then: flip flags on, restore from the frozen `unseal.json` + last `raft-*.snap` + `vault-tls` export, re-enable ESO stores per ADR-002.

## Consequences

### Positive

- Velocity restored: secret change = edit + `sops encrypt` + commit + PR, with Git diffs and rollback.
- DR honest: `git clone` + 1 age key + RustFS bootstrap prefix recovers secrets without a running cluster.
- Vault knowledge preserved: code, ADR-002/009, and the frozen archive under `s3://secrets-homelab` stay searchable. The Vault-specific `docs/runbook-vault-restore.md` was deleted on 2026-09-28; ADR-009 keeps the golden rule that mattered, and the cluster restore procedure lives in [`docs/velero.md` §6](../velero.md#6-restore-runbook).

### Negative

- New root of trust: age private key. Loss without offline copy = re-encrypt everything. Mitigated by dual copy (RustFS + offline).
- ArgoCD does not decrypt SOPS natively: encrypted secrets apply via `init-sops.sh` / CI step, outside the ArgoCD sync wave.
- Until the flags above, pausing was manual (`kubectl delete application vault`). The flags are the mechanism.

### Risks

- **Age key in CI logs:** decrypt only in memory, never `cat` the key file in Jobs; `shred -u` after apply.
- **Bucket confusion:** `velero-homelab` vs `secrets-homelab` prefixes must stay distinct; bucket-init Jobs stay idempotent (`BucketAlreadyOwnedByYou` = success).
- **Silent re-activation:** flipping `vault.enabled` without the frozen archive re-creates the half-migrated DR gap (keys in-cluster vs S3). ADR + runbook link mitigate.

## Files

| Action | File |
|--------|------|
| Created | `docs/adrs/017-vault-paused-sops-default.md` — this ADR |
| Created | `.sops.yaml` — age recipients for `platform/*/sops/*.enc.yaml` |
| Created | `bootstrap/init-sops.sh` — pull age key from `s3://secrets-homelab/sops/keys.txt`, guard `templates/`, decrypt + `kubectl apply`, shred key |
| Created | `platform/seaweedfs/sops/admin-credentials.enc.yaml`, `s3-credentials.enc.yaml` — first SOPS secrets |
| Created | `platform/monitoring/sops/grafana-admin.enc.yaml`, `loki-s3-credentials.enc.yaml` — first SOPS secrets |
| Updated | `gitops/templates/platform/01-vault.yaml` — gate on `.Values.vault.enabled` |
| Updated | `gitops/templates/platform/00-external-secrets.yaml` — gate on `.Values.eso.enabled` |
| Updated | `gitops/values.yaml`, `gitops/values-dev.yaml` — `vault.enabled: false`, `eso.enabled: false` |
| Updated | `.github/workflows/deploy.yaml` — install `sops v3.10.2`, restore age key + apply encrypted secrets |
| Updated | `justfile` (`secrets-apply`) — run `init-sops.sh` first |
| Moved | `platform/*/templates/*.yaml` → `platform/*/templates/secrets/*.yaml` — keep `templates/` free of `*.enc.yaml` |
| Frozen | `platform/vault/**` — no functional changes while paused |

## References

- ADR-002: Vault config decentralization (per-service ESO stores)
- ADR-004: Tailscale OAuth seed strategy (bootstrap Secret outside Vault — same chicken-egg precedent)
- ADR-009: Vault DR — single-leader restore + raft snapshot golden rule
- Runbook: `docs/runbook-vault-restore.md` (deleted 2026-09-28; golden rule in [ADR-009](009-vault-dr-and-velero-backup.md) §Decision 1, cluster restore procedure in [`docs/velero.md` §6](../velero.md#6-restore-runbook))
- Velero: `docs/velero.md`, `platform/velero/values.yaml`
- SOPS: https://github.com/mozilla/sops — age: https://github.com/FiloSottile/age
