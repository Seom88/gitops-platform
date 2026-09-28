# ADR-009: Vault DR — Proxmox VM Restore Non-Atomic + Velero/RustFS as Complement

**Status:** Accepted · **Date:** 2026-09-01

> [!NOTE]
> **Addendum 2026-09-28 — runbook deleted, golden rule retained.** The canonical runbook this ADR pointed to (`docs/runbook-vault-restore.md`, 377 lines) has been **deleted**. It documented a 3-VM Proxmox Raft topology that no longer exists: [ADR-019](019-single-node-bare-metal-migration.md) moved the cluster to one bare-metal node and reduced Vault to `server.ha.replicas: 1` with Longhorn `defaultReplicaCount: 1`; commit `b43d1f4` replaced the autounseal `CronJob` with a `Deployment`; [ADR-017](017-vault-paused-sops-default.md) then paused Vault itself. Every procedure in it was therefore unrunnable as written.
>
> **What survives:** the decision itself. §Decision 1 — never restore divergent Raft logs, and use `vault operator raft snapshot save/restore` for atomic point-in-time recovery — is unchanged and, on a single replica, reduces to: **restore the last `raft-*.snap` from the frozen archive; never attempt a VM-level replay.** §Decision 3 (Velero as an external-RustFS complement) is likewise unchanged; the cluster-wide restore path that replaced the runbook is [`docs/velero.md` §6](../velero.md#6-restore-runbook).
>
> **What does not survive:** the version pins and wave numbers in the body below (Velero `9.0.2` → wrapper chart `12.2.0` / app `1.18.1`, AWS plugin `v1.10.2` → `v1.14.3`, `aws-cli:2.15.0` → `2.37.4`, `velero-bucket-init` wave `-1` → `Sync` hook at wave `0`, `vault-hourly` schedule retired and `disabled: true`). These are left as written because an ADR is a point-in-time record — read them as history, not as current state.

## Context

Vault runs as 3-replica Raft (`vault-0`, `vault-1`, `vault-2`) on Longhorn PVCs (`data-vault-0/1/2`) with TLS `vault-tls` and autounseal via `vault-autounseal` CronJob (see `platform/vault/templates/unseal/`). The cluster is wave `1` (`gitops/templates/apps/01-vault.yaml`), after `longhorn` wave `0`. Secrets for every platform service are delivered via ESO `ClusterSecretStore` per ADR-002.

Two backup layers existed before this ADR:

1. **Proxmox `vzdump` VM-level** — hypervisor snapshots of each Talos/VM node sequentially (not coordinated). Each VM image is crash-consistent locally, but the three dumps are taken at `T0`, `T1`, `T2` seconds apart.
2. **No Kubernetes-native backup** — Velero was not yet deployed (`docs/roadmap.md` Phase 3 `Velero` was `[ ]`).

The failure was observed after restoring **all 3 Vault VMs** from their respective vzdump archives (tested after a simulated cluster loss):

| Pod | Phase | `vault status` | Diagnosis |
|-----|-------|----------------|-----------|
| `vault-0` | `CrashLoopBackOff` | `sealed=true` or `x509: certificate signed by unknown authority` | Raft log diverged; followers rejected `AppendEntries` (term mismatch, stale `peers.json`) |
| `vault-1` | `Running` | `initialized=false` | Raft data wiped or peers entry missing; not voter |
| `vault-2` | `Running` | `initialized=true sealed=false standby=false` (leader) | Only peer with quorum-real log |

Raft is linearizable only on a single log. Restoring three divergent logs breaks quorum: no peer reaches term `43` with index `1215` (leader `vault-2`) while `vault-0` is at term `42` index `1200` and `vault-1` at `42/1207`. `raft list-peers` shows `failed to join raft cluster: not a voting member`.

The legacy `vault-autounseal` CronJob ran at `*/15` and only attempted `vault operator unseal`. It did not handle `initialized=false` (needs `raft join`) nor `CrashLoop` peers (needs `raft remove-peer`). Recovery required manual `kubectl exec` for every pod and did not self-heal on the next cycle.

Velero was evaluated as complement. The natural design would be `Vault (secret/rustfs) → ExternalSecret → Secret velero/cloud-credentials → Velero`, but Velero **backs up Vault** (`vault-tls`, `vault-unseal-keys`, PVCs, `vault-autounseal` CronJob). If Velero's S3 credentials come from Vault/ESO, a bare-metal restore deadlocks: Vault down → ESO cannot render Secret → Velero cannot start → no restore. This is the same chicken-egg as ADR-004 option A (Tailscale OAuth seed).

The bucket creation itself was an open question: whether to require local `aws-cli` / CI step or to make it GitOps-automated.

## Options Considered

### Option A — Restore 3 VMs Proxmox as-is (REJECTED)

Restore `qemu 101/102/103` (or equivalent) for all three Vault nodes from their vzdump archives and let Raft converge.

**Pros:** Simple Proxmox operation; no extra tooling.

**Cons:** Non-atomic vzdump replays divergent Raft logs (see §3 of runbook). Verified to produce `vault-0 CrashLoop`, `vault-1 not initialized`, `vault-2 unsealed` split-brain. No self-heal at `*/15` unseal-only. Requires manual `remove-peer`/`join` every time. Violates Raft linearizability.

### Option B — Single-Leader Restore + Raft Snapshot Save/Restore (SELECTED — Golden Rule)

Restore **only one VM** at Proxmox level (conventionally `vault-2`, the last ordinal, stable StatefulSet identity on node `cp-3`), **wipe followers' PVCs** (`data-vault-0`, `data-vault-1`), then `vault operator raft join` empty followers via `https://<leader>.vault-internal.vault.svc.cluster.local:8200` and `vault operator unseal`.

For point-in-time atomic restore, prefer `vault operator raft snapshot save /tmp/vault-raft.snap` (leader) → store off-cluster (RustFS, encrypted disk) → `raft snapshot restore` on the single leader before follower join. This is the only atomic DR primitive for Raft; vzdump is not atomic, Velero is not Raft-linearizable.

**Pros:** Atomic when using `raft snapshot`; single-leader VM restore is deterministic and reproducible; followers re-join empty (no divergent log); `vault-autounseal` can automate `remove-peer` + `join` + `unseal` (see Decision). Verified to recover `vault-0/1` from `not initialized` / `CrashLoop` within 2–4 min.

**Cons:** Requires knowing which VM is `vault-2` (or any known leader); manual PVC delete step if autounseal is not yet `*/2` with raft recovery.

### Option C — Velero with SeaweedFS Internal S3 (REJECTED)

Configure Velero `backupStorageLocation` to SeaweedFS S3 (`seaweedfs` wave `2`, `s3.lonk-mirfak.ts.net` via Tailscale ingress, bucket `velero` on `filer`).

**Pros:** S3 stays inside the cluster (no external dependency), reuses `platform/seaweedfs` already deployed, no Tailscale external endpoint needed for Velero.

**Cons:** **Cluster-loss chicken-egg**: if the cluster is lost, SeaweedFS is also lost, so Velero backups are unreachable — exactly when they are needed. Additionally, Velero wave `0` vs SeaweedFS wave `2` ordering inversion (Velero would depend on a later wave). Rejected for DR viability; RustFS external survives cluster loss.

### Option D — Velero with RustFS External S3 (SELECTED — Complement)

Velero `9.0.2` (`vmware-tanzu/velero`, wrapper `platform/velero 1.0.0`, `appVersion 1.14.1`) with `backupStorageLocation` `aws` provider on RustFS `https://rustfs.lonk-mirfak.ts.net`, bucket `velero-homelab`, `prefix velero/`, `region us-east-1`, `s3ForcePathStyle true`, `s3Url` identical to endpoint. `volumeSnapshotLocation` present (`snapshotVolumes: false`, required by chart), `nodeAgent.enabled: true`, `defaultVolumesToFsBackup: true` (Longhorn volumes via filesystem copy, no CSI snapshots), schedules `daily-full 0 2 * * *` (all ns, TTL 30d) and `vault-hourly 0 * * * *` (ns `vault`, resources `secrets/configmaps/pvc/cronjobs`, TTL 7d), plugin `velero-plugin-for-aws v1.10.2`.

Credentials **outside** Vault/ESO: ephemeral Secret `velero/cloud-credentials` (key `cloud` ini `[default]`) created by `bootstrap/init-gitops.sh:ensureVeleroCredentials()` (prefers `VELERO_AWS_ACCESS_KEY_ID`/`VELERO_AWS_SECRET_ACCESS_KEY`, fallback `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` — same RustFS keys as Terraform state `terraform-homelab`). Chart consumes via `credentials.existingSecret: cloud-credentials` (`useSecret: true`). Follows precedent ADR-004 option A (bootstrap Secret outside Vault).

Velero is wave `0` (with `longhorn`), before `vault` wave `1` — guarantees `BackupStorageLocation Ready` before Vault PVCs exist.

**Pros:** Velero autonomous without ESO/Vault (no deadlock on bare-metal restore); external RustFS survives cluster loss; S3-compatible path-style works with `aws-cli`; `nodeAgent` backs up Longhorn PVCs without CSI; schedules cover `vault-hourly` unseal keys + TLS.

**Cons:** External bucket depends on Tailscale `rustfs.lonk-mirfak.ts.net` reachability; credentials in `deploy.yaml` env (handled via `VELERO_AWS_*` or `AWS_*` fallback); `nodeAgent` DaemonSet overhead (one pod per node, `200m/256Mi` requests).

**Important:** Velero **complements** but does not replace `raft snapshot` — Velero captures Kubernetes objects and volume filesystem, not Raft linearizability. For Vault quorum recovery, `raft snapshot save/restore` (§B) and single-leader VM restore remain the golden rule.

### Option E — Bucket Creation: `aws-cli` in CI vs. In-Cluster Job Wave `-1` (SELECTED: Job)

**E1 — `aws-cli` in CI / local:** add step in `.github/workflows/deploy.yaml` running `aws s3api create-bucket` with `VELERO_AWS_*` env.

**Pros:** Explicit; no in-cluster Job.

**Cons:** Requires `aws-cli` installed in runner, duplicates credential handling, not GitOps-automated, manual re-run if bucket deleted, diverges from ArgoCD sync model.

**E2 — Job `velero-bucket-init` wave `-1` (SELECTED):** `platform/velero/templates/job-bucket-init.yaml`, `batch/v1` `Job`, wave `-1` (before wave `0` chart), `Prune=false` + `ttlSecondsAfterFinished: 600`, image `amazon/aws-cli:2.15.0`, `serviceAccountName: default` (avoids chicken-egg with subchart SA), mounts `Secret cloud-credentials` at `/etc/velero/cloud`, parses ini via `grep`/`cut`, idempotent `create-bucket --bucket velero-homelab --endpoint-url https://rustfs.lonk-mirfak.ts.net --region us-east-1 2>&1 || true` then `head-bucket` verification, treats `BucketAlreadyOwnedByYou|BucketAlreadyExists|already exists` as success, `restartPolicy: OnFailure` `backoffLimit: 3`.

**Pros:** Fully GitOps-automated, reuses Secret already created by `ensureVeleroCredentials()`, no local `aws-cli` or CI step, idempotent on re-sync, logs inspectable until GC.

**Cons:** Depends on Secret existing before Job start (bootstrap must run with env).

## Decision

1. **Golden rule for Vault DR:** restore **only `vault-2`** at Proxmox VM level, delete `data-vault-0`/`data-vault-1` PVCs, `kubectl delete pod vault-0 vault-1`, let followers re-join empty. Never restore all 3 VMs from vzdump. Use `vault operator raft snapshot save/restore` for atomic point-in-time restores (off-cluster storage). Documented in `docs/runbook-vault-restore.md` — **deleted 2026-09-28**, see addendum; this decision is the surviving record.

2. **Autounseal hardening:** `vault-autounseal` CronJob `schedule: "*/2 * * * *"` (was `*/15`), `platform/vault/templates/unseal/configmap-autounseal.yaml` script with Raft recovery: validates `vault-tls` CA, reads `key1..keyN` dynamically (supports 3 or 5), selects healthy leader (prefers `vault-2`), for each pod does `raft remove-peer` if `CrashLoop`/`not Running`, `raft join https://<leader>.vault-internal.vault.svc.cluster.local:8200` if `initialized=false`, `operator unseal` with all keys if `sealed=true` (TLS-aware, retry 3, timeout 20). `CronJob` image `bitnami/kubectl:latest`, `concurrencyPolicy: Forbid`, `activeDeadlineSeconds: 300`.

3. **Velero complement with RustFS external:** `platform/velero` wave `0` (`gitops/templates/apps/05-velero.yaml`, `CreateNamespace=true`, `ignoreDifferences` for Job immutables), `velero-homelab` bucket, `prefix velero/`, `region us-east-1`, `s3ForcePathStyle true`, `s3Url https://rustfs.lonk-mirfak.ts.net`, plugin `v1.10.2`, `nodeAgent true`, schedules `daily-full` + `vault-hourly`. Credentials via `ensureVeleroCredentials()` outside Vault/ESO. Rejects SeaweedFS internal S3 for cluster-loss survivability.

4. **Bucket init:** wave `-1` Job `velero-bucket-init` idempotently creates `velero-homelab` before Velero chart; `Prune=false`.

5. **Runbook location (superseded 2026-09-28):** canonical `docs/runbook-vault-restore.md` (moved from `platform/vault/scripts/`). A stub at the previous vault scripts location with `Moved → ../../docs/runbook-vault-restore.md` was kept for backward links. Both are now **deleted** — the stub never existed, and the runbook is replaced by the cluster restore procedure in `docs/velero.md` §6. All inbound references were repointed there.

## Consequences

### Positive

- **Atomic DR:** `raft snapshot save/restore` gives point-in-time consistency; single-leader vzdump restore gives deterministic Raft quorum (verified: `vault-0/1` heal from `CrashLoop`/`not initialized` in 2–4 min).
- **Velero autonomous without ESO:** `cloud-credentials` outside Vault avoids deadlock on bare-metal restore (ADR-004 precedent); wave `0` guarantees BSL Ready before Vault wave `1`.
- **Bucket autocreated:** wave `-1` Job makes `velero-homelab` GitOps-native; no manual `aws s3api` or CI `aws-cli` step required unless Job cannot run (fallback documented).
- **Self-healing:** `vault-autounseal` `*/2` with Raft recovery automatically does `remove-peer` → `join` → `unseal` without manual `kubectl exec` per incident.
- **DR complement separation:** Velero for Kubernetes objects + Longhorn volumes (via `nodeAgent`), Raft snapshot for log linearizability, vzdump single-leader for full VM rebuild — each layer has clear scope.

### Negative

- **External dependency:** Velero bucket depends on RustFS Tailscale reachability (`rustfs.lonk-mirfak.ts.net`); if Tailscale or RustFS is down, `BackupStorageLocation` is `NotReady` and backups/restores block. Evaluated alternative SeaweedFS internal was rejected for the worse property (cluster loss → backup loss).
- **NodeAgent overhead:** DaemonSet `velero-node-agent` on every node (`200m/256Mi req`, `500m/512Mi lim`) for `defaultVolumesToFsBackup` even when not backing up. Acceptable at 3-node homelab scale.
- **Credential handling:** `VELERO_AWS_*` (preferred) or `AWS_*` fallback in `deploy.yaml` env and `init-gitops.sh` — same RustFS keys as `terraform-homelab` unless operator separates them. No Vault rotation automation yet.
- **Hook log ephemerality:** `vault-autounseal` Jobs are short-lived (`successfulJobsHistoryLimit: 3`); debugging requires re-sync or `kubectl logs job/...` within 10 min window (TTL).

### Risks

- **Misapplied single-leader rule:** restoring all 3 VMs again re-creates split-brain; mitigate via runbook prominence and ADR-009 + `docs/velero.md` cross-link.
- **Bucket deletion without Job re-run:** if `velero-homelab` is deleted off-cluster, next Argo sync re-runs Job idempotently (`create-bucket` → success), but backups between deletion and re-creation are lost. Mitigate with Velero `daily-full` frequency and external RustFS lifecycle.
- **CA drift after VM restore:** restored `vault-2` may have stale `vault-tls` CA vs live `Certificate`; autounseal validates CA and warns `CA file not found` — manual `cert-manager` re-issue or Velero `vault-hourly` restore of `vault-tls` Secret resolves.
- **TLS server name mismatch:** autounseal retries with and without `-tls-server-name=vault` to tolerate misconfiguration, but persistent misconfiguration would require chart fix (`platform/vault/values.yaml`).

## Files

| Action | File |
|--------|------|
| Created | `platform/velero/values.yaml` — RustFS `velero-homelab`, `prefix velero/`, `region us-east-1`, `s3ForcePathStyle true`, `s3Url https://rustfs.lonk-mirfak.ts.net`, `credentials.existingSecret cloud-credentials`, `nodeAgent true`, `schedules daily-full + vault-hourly`, plugin `v1.10.2` |
| Created | `platform/velero/templates/job-bucket-init.yaml` — wave `-1` Job `velero-bucket-init` (`amazon/aws-cli:2.15.0`, `Prune=false`, `ttlSecondsAfterFinished: 600`, idempotent `create-bucket` + `head-bucket`) |
| Created | `platform/velero/templates/namespace.yaml` — `Namespace velero` |
| Created | `platform/velero/Chart.yaml` + `Chart.lock` + `charts/velero-9.0.2.tgz` — wrapper `velero 1.0.0` on `vmware-tanzu/velero 9.0.2` |
| Created | `platform/velero/README.md` — Velero deep-dive, flows, troubleshooting, relation to Vault DR |
| Created | `docs/velero.md` — chicken-egg, mermaid bootstrap flow, wave table, Job spec, secrets/CI matrix, verification |
| Created | `gitops/templates/apps/05-velero.yaml` — ArgoCD `Application velero` wave `0` (`CreateNamespace=true`, `ignoreDifferences` for Job immutables) |
| Updated | `bootstrap/init-gitops.sh:ensureVeleroCredentials()` — creates `ns velero` + `Secret cloud-credentials` from `VELERO_AWS_*` fallback `AWS_*`, idempotent |
| Updated | `platform/vault/templates/unseal/configmap-autounseal.yaml` — `unseal.sh` with `*/2` raft recovery (`remove-peer`/`join`/`unseal`, CA validation, dynamic keys, parse helpers, retry 3) |
| Updated | `platform/vault/templates/unseal/cronjob-autounseal.yaml` — `schedule: "*/2 * * * *"` (was `*/15`), `concurrencyPolicy: Forbid`, `activeDeadlineSeconds: 300` |
| Moved (later deleted) | `docs/runbook-vault-restore.md` (canonical, previously under `platform/vault/scripts/`) — golden rule, procedures A/B/C, verification, troubleshooting; previous path now a stub `Moved → ../../docs/runbook-vault-restore.md`. **Removed 2026-09-28** — the stub claim was already false and the procedures targeted a retired 3-VM topology. |
| Updated (later repointed) | `docs/velero.md`, `platform/velero/README.md` — references now point to `docs/runbook-vault-restore.md` (relative `runbook-vault-restore.md` / `../../docs/runbook-vault-restore.md`). **Repointed 2026-09-28** to `docs/velero.md` §6 and ADR-009 §Decision 1. |
| Updated | `docs/ci-cd.md` §Velero bootstrap — summary of `ensureVeleroCredentials()` + wave `-1` Job |
| Created | `docs/adrs/009-vault-dr-and-velero-backup.md` — this ADR |

## References

- Runbook: `docs/runbook-vault-restore.md` — single-leader Proxmox restore + Raft snapshot + Velero complement, `vault-autounseal` `*/2` — **deleted 2026-09-28; golden rule retained in §Decision 1, cluster restore procedure in [`docs/velero.md` §6](../velero.md#6-restore-runbook)**
- Deep-dive Velero: `docs/velero.md` — chicken-egg, bootstrap flow, wave ordering, Job spec, secrets/CI, verification, troubleshooting
- CI/CD: `docs/ci-cd.md` — `validate.yaml`/`deploy.yaml`, `ensureVeleroCredentials()` summary
- Precedent: `docs/adrs/004-tailscale-oauth-seed-strategy.md` option A — bootstrap Secret outside Vault/ESO
- SeaweedFS diff: `docs/adrs/008-seaweedfs-statefulset-volumeclaimtemplates-diff.md` — format reference for this ADR
- Jobs as hooks: `docs/adrs/007-argocd-jobs-as-sync-hooks.md` — `BeforeHookCreation` pattern for immutable Jobs (vault-config precedent)
- Vault Raft: https://developer.hashicorp.com/vault/docs/enterprise/raft — `operator raft snapshot save/restore`, `join/remove-peer/list-peers`
- Velero: https://velero.io/docs/ — AWS plugin, `BackupStorageLocation`, `nodeAgent` (restic), `Schedule`
- Proxmox: https://pve.proxmox.com/wiki/Backup_and_Restore — `vzdump`, `qmrestore`

