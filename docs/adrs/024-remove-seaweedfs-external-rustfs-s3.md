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
