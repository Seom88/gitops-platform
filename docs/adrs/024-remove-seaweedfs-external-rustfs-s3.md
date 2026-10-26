# ADR-024: Remove the SeaweedFS Chart — Consolidate on External RustFS S3

**Status:** Accepted · **Date:** 2026-10-13 · **Deciders:** Seom88 · **Related:** [ADR-009](009-vault-dr-and-velero-backup.md), [ADR-013](013-alloy-replaces-promtail.md), [ADR-014](014-cilium-cni-and-identity-networkpolicies.md), [ADR-017](017-vault-paused-sops-default.md)

## Context

Before this change the platform shipped an in-cluster SeaweedFS deployment (`platform/seaweedfs/`, wave 2): four `StatefulSet`s (master, volume, filer, admin), its own PVCs, SOPS-encrypted credentials, a dedicated namespace, and per-namespace `CiliumNetworkPolicy`. Its only live consumer in the repo was Loki's S3 backend (`seaweedfs-s3.seaweedfs.svc:8333`); Velero already used the external RustFS endpoint because backups cannot live where the cluster they protect lives (ADR-009 option C → option D).

Running a second, in-cluster S3 just for Loki duplicated a concern that RustFS already solves out of cluster, and it kept a whole chart, its secrets, its templates, and its policies on a feature path that no user-facing application depended on (ADR-006 listed it as a wave-2 *infrastructure* step, not an app).

Commit `0759031` (`Refactor remove SeaweedFS`) cut Loki over to the external RustFS endpoint and deleted `platform/seaweedfs/` outright; commit `892f65e` finished the doc-surface cleanup. Commit `48fd554` then completed the IAM story for that cutover: the `loki` bucket-init Job (now rendered from the shared `platform/s3-bucket-lib`) creates the `loki` bucket itself, so the scoped `loki-backup` key needs `s3:CreateBucket` on `arn:aws:s3:::loki` in addition to the object verbs already granted (see `docs/rustfs-iam.md`).

## Decision

1. **Remove `platform/seaweedfs/` entirely** — chart, templates, PVCs, secrets, ESO stores, ServiceMonitor, policies, values. No SeaweedFS `Application` is generated (`gitops/templates/platform/02-seaweedfs.yaml` → `02-valkey.yaml`).
2. **Loki backs onto external RustFS** (`rustfs.lonk-mirfak.ts.net`, bucket `loki`) via its existing S3 storage block; bucket creation is delegated to the idempotent `loki-bucket-init` Job.
3. **All S3 consumers use the same external endpoint family** — Velero (`velero-homelab`) and Loki (`loki`) buckets share RustFS and the documented Tailscale/LAN resolution path.
4. **Update IAM guidance**: `loki-backup` must hold `s3:CreateBucket` scoped to `arn:aws:s3:::loki` because the Job creates the bucket; the key still has no access to any other bucket.

ADRs and historical notes that referenced SeaweedFS as live state (ADR-006 wave 2, ADR-008, ADR-013, ADR-014, ADR-015, ADR-017, ADR-018, ADR-021) are amended to point here instead of describing the chart as deployed.

## Consequences

### Positive

- One S3 implementation to operate and back up: external RustFS, which already survives cluster loss (ADR-009).
- A whole chart, its secrets, and its policy surface disappear; the `seaweedfs` namespace stops being deployed and stops being in ADR-014's coverage list.
- Loki leaves the staging `seaweedfs-s3` in-cluster dependency behind: a cluster rebuild no longer needs to wait for 4 SeaweedFS pods before logs can be written.

### Negative

- **External dependency hardens.** Every log ingestion now depends on `rustfs.lonk-mirfak.ts.net` reachable over Tailscale and on the bucket's IAM policy. A RustFS outage or a bad `loki-backup` key makes the bucket-init Job (and therefore Loki's readiness) fail loudly — preferable to a silently empty S3 backend.
- **Historical ADRs go stale by construction.** ADR-008 in particular documents an ArgoCD `ignoreDifferences` fix against a chart that no longer exists. It is kept as a record of that ArgoCD behaviour, annotated rather than deleted.
- **No in-cluster S3 fallback.** There is no second backend; rollback to SeaweedFS would mean re-introducing the whole chart (git history retains it).

## Verification

- `git grep -n seaweedfs platform/ gitops/` returns no chart or template references outside documentation.
- `helm template monitoring platform/monitoring` renders the `loki-bucket-init` Job and no `seaweedfs` resources.
- `docs/rustfs-iam.md` matches the IAM used in the RustFS console (`s3:CreateBucket`, `s3:GetObject`, `s3:PutObject`, `s3:DeleteObject`, `s3:AbortMultipartUpload`, `s3:ListMultipartUploadParts`, `s3:ListBucket`, `s3:ListBucketVersions`, `s3:ListBucketMultipartUploads`, `s3:GetBucketVersioning` scoped to `arn:aws:s3:::loki`).

## Amendment 2026-10-26: Loki Leaves External S3 for a Local Longhorn Volume

**Status:** Accepted · **Date:** 2026-10-26 · **Deciders:** Seom88 · **Amends:** decisions 2, 3 and 4 · **Related:** [ADR-025](025-solar-energy-aware-operations.md), [ADR-019](019-single-node-bare-metal-migration.md)

Decision 2's premise — that Loki must back onto external RustFS — did not survive contact with the energy budget. This amendment reverses it for Loki only. Velero and CNPG/Barman still use RustFS exactly as ADR-009 and ADR-024 established; nothing else in this ADR changes.

### Why the decision was reversed

1. **Loki was the only always-on RustFS writer.** Measured 2026-10-26 from cAdvisor container-network counters (Loki's own `loki_*` metrics are not scraped — the chart ships no `ServiceMonitor`): the `monitoring-loki-0` pod averaged 4.25 KB/s egress, roughly **368 MB/day of chunks written continuously**. Velero (`0 18 * * *`) and Barman backups are scheduled bursts that let disks sleep between windows; Loki's write path never idles, so the TrueNAS HDDs never spun down. That is precisely the standing load [ADR-025](025-solar-energy-aware-operations.md) exists to eliminate.
2. **The survival property bought less than it cost.** ADR-024's positive case was that logs survive cluster loss because they live outside it. But Loki retains only 14 days, and the operator accepted losing that history outright — the external copy protected data nobody intended to keep, while adding a hard dependency on a VM that restarts frequently.
3. **The dependency was inverted risk.** "Every log ingestion now depends on `rustfs.lonk-mirfak.ts.net`" was listed here as a negative and is the one that materialised: a TrueNAS restart broke logging, the component meant to diagnose restarts.

### Amended decision

- **Loki uses `filesystem` storage** on its own Longhorn PVC: `common.storage.filesystem` at `/var/loki/chunks` and `/var/loki/rules`, `object_store: filesystem` in a single schema entry starting `2026-10-26`. Longhorn stores the replicas on node-local disk, so log writes never cross the tailnet.
- **Retention is 14 days** (`limits_config.retention_period: 336h`, compactor enabled with `delete_request_store: filesystem`). Without it Loki keeps everything and fills the claim. The PVC is 10 Gi, sized from the measured 368 MB/day (~5.2 GB of chunks over 14 days) plus index and compactor working space; Longhorn allows expansion.
- **The volume is excluded from Velero** by PVC annotation `velero.io/exclude-from-backup: "true"`. Disaster recovery for logs is "you lose the 14 days"; the `logs` from the cluster being restored are more useful than the ones behind it. Loki also stops participating in the `daily-full` FsBackup, which previously copied the PVC every night.
- **The `loki` bucket, its scoped key, the `loki-bucket-init` Job, the `vault-loki-s3` ExternalSecret and `sops/loki-s3-credentials.enc.yaml` are removed from the repo.** The Cilium egress allowlist drops the Loki→RustFS FQDN and CIDR rules. Grafana's Barman backup keeps its own `grafana-backup-to-rustfs-s3` policy, so `backup.tailnetIp` remains in use.
- **Old chunks are abandoned.** Anything still in the RustFS `loki` bucket is unreachable through the new schema: queries for ranges before 2026-10-26 return no data. The bucket and `loki-backup` key may be deleted from the console.

### Consequences

- Log ingestion no longer depends on RustFS, Tailscale or the TrueNAS VM. A TrueNAS restart now affects backups only.
- Logs are no longer cluster-loss-durable. Accepted: 14 days of disposable data, and the PVC survives workload restarts because it is a Longhorn volume, not `emptyDir`.
- New failure mode: a full volume silently stops ingestion. Mitigated by 14-day retention (~50% headroom at 10 Gi) and by watching `kubelet_volume_stats_available_bytes` for `storage-monitoring-loki-0`; expand with `size:` in `values.yaml` and a PVC patch (Longhorn supports online expansion).
- Longhorn snapshots are a separate axis: monitoring volumes opt out through the `recurring-job-group.longhorn.io/no-snapshot` label on the Volume CR, applied manually after provisioning. A recreated Loki volume must have it re-applied, or the `default` 2-hour snapshot group will start snapshotting it.

### Verification

- `helm template monitoring platform/monitoring` renders `common.storage.filesystem`, a single `2026-10-26` schema entry with `object_store: filesystem`, `retention_period: 336h`, `delete_request_store: filesystem`, a 10 Gi `longhorn` claim annotated `velero.io/exclude-from-backup`, and no `loki-bucket-init`, `loki-s3-credentials`, or RustFS egress rule.
- `git grep -n 'loki-s3\|loki-bucket-init'` returns only historical task documents under `odd/tasks/`.
