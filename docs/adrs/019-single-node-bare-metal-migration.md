# ADR-019: Single-Node Bare-Metal Migration (3w to 1w Topology)

**Status:** Accepted · **Date:** 2026-09-26 · **Deciders:** Seom88 · **Related:** [ADR-016](016-two-node-prod-trial.md), [ADR-015](015-lean-cpu-sizing-homelab-vs-datacenter.md)

> **Outcome:** cluster reduced from 3 workers to 1 worker. Vault standalone (1 replica), Longhorn 1 replica, all podAntiAffinity commented out. Motivation: resource savings and migration from k8s-on-VM to bare metal.

## Context

The homelab runs on 3 worker VMs. The user plans to migrate to bare metal with a single node to reduce resource consumption and simplify the infrastructure. The goal is to maintain pod-level HA where possible while accepting that true multi-node HA is no longer available.

## Decision

| Component | Before (3 nodes) | After (1 node) | Rationale |
|---|---|---|---|
| Vault server | 3 replicas (Raft) | **1 replica** (standalone) | Raft quorum requires ≥3 nodes; with 1 node, standalone is the only option. Autounseal covers restarts. |
| Vault injector | 2 replicas | **2 replicas** | Stateless webhook; zero-downtime restarts. |
| Immich server | 1 replica | **1 replica** | Unchanged. |
| Immich machine-learning | 1 replica | **1 replica** | GPU workload — only 1 GPU available on single node. |
| Homepage | 1 replica | **2 replicas** | Stateless dashboard; zero-downtime restarts. |
| Grafana | 1 replica (default) | **2 replicas + shared CNPG Postgres** | Stateful (SQLite by default): 2 replicas on SQLite caused the 401 `user token not found` login loop. Zero-downtime restarts kept via the shared `grafana-database` cluster (in platform/monitoring, wave 3; operator at wave -1). |
| Alertmanager | 1 replica | **2 replicas** | Stateless alerting; zero-downtime restarts. |
| Loki gateway | 1 replica (default) | **1 replica** | Chart's hard `podAntiAffinity` cannot be disabled via `affinity: {}` (Helm deep-merge preserves it); 2 replicas unschedulable on single node. Zero-downtime restarts lost. |
| Loki singleBinary | 1 replica | **1 replica** | Stateful, 1 PVC. |
| Longhorn `longhorn-prod` | 3 replicas | **1 replica** | No distribution possible; snapshots + S3 backups retained. |
| Longhorn default | 2 replicas | **1 replica** | Idem. |
| `podAntiAffinity` | Active (required + preferred) | **Commented out** where possible; **replicas reduced to 1** where chart hard-codes it (Loki gateway) | Cannot be satisfied with a single `kubernetes.io/hostname` topology key. Loki chart's affinity survives `affinity: {}` due to Helm deep-merge; `null` also fails. Only fix: reduce replicas to 1. |

## Tradeoffs

### Lost
- **Multi-node HA**: node failure = total downtime. No pod redistribution.
- **Raft quorum**: Vault loses consensus; standalone mode only.
- **Longhorn distributed storage**: no replica redundancy; data loss if disk fails without backup.
- **Rolling updates**: no zero-downtime node drains.

### Retained
- **Pod restart**: kubelet restarts failed pods on the same node.
- **PDBs**: protect against voluntary disruptions (upgrades, drains).
- **Longhorn snapshots**: local fast recovery.
- **Longhorn S3 backups** (RustFS): off-cluster disaster recovery.
- **Velero backups**: cluster-level recovery.

### GPU / Immich ML
- Single node = single GPU. `machine-learning` stays at 1 replica.
- If GPU is added later, 2 replicas of ml are not feasible (only 1 GPU).

### Future: Second Disk for Longhorn
- If a second physical disk is added to the node, Longhorn can run 2 replicas with `replicaDiskSoftAntiAffinity: false`, placing each replica on a different disk.
- This provides **disk-level redundancy** within the same node (survives single disk failure, not node failure).
- Currently: 1 disk → 1 replica. Future: 2 disks → 2 replicas possible.

### Future: iSCSI with TrueNAS
- TrueNAS can expose iSCSI LUNs to Kubernetes as additional storage.
- Currently TrueNAS is limited to **backups only** (Velero BSL, Longhorn S3 backup target).
- If iSCSI is adopted in the future, it could provide:
  - Additional Longhorn disks (via iSCSI) for multi-disk redundancy.
  - Alternative storage class for workloads that need block storage without Longhorn replication.
- Not implemented now: adds complexity (iSCSI initiator, network config, TrueNAS dependency).

## Changes

| File | Change |
|---|---|
| `platform/vault/values.yaml` | `injector.replicas: 2→1`, `server.ha.replicas: 3→1`, both `affinity` blocks commented |
| `apps/immich/values.yaml` | Both `podAntiAffinity` blocks (server + ml) commented |
| `platform/longhorn/templates/storageclass.yaml` | `numberOfReplicas: "3"→"1"` |
| `platform/longhorn/values.yaml` | `defaultReplicaCount: 2→1`, `defaultClassReplicaCount: 2→1` |

## Rollback

1. Revert `server.ha.replicas` to `3` in `platform/vault/values.yaml`.
2. Revert `injector.replicas` to `2`.
3. Uncomment both `affinity` blocks in `platform/vault/values.yaml`.
4. Revert `numberOfReplicas` to `"3"` in `platform/longhorn/templates/storageclass.yaml`.
5. Revert `defaultReplicaCount` and `defaultClassReplicaCount` to `2` in `platform/longhorn/values.yaml`.
6. Uncomment both `affinity` blocks in `apps/immich/values.yaml`.
7. Scale back to 3 worker nodes in the infra repo.

## Next steps

- [ ] Apply changes via ArgoCD sync.
- [ ] Verify Vault unseals (autounseal CronJob).
- [ ] Verify Longhorn volumes are healthy with 1 replica.
- [ ] Test backup/restore cycle (Longhorn → RustFS).
- [ ] Monitor resource usage on single node.
