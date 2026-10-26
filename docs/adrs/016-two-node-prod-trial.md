# ADR-016: Two-Worker Prod Trial (3w to 2w Topology)

**Status:** Abandoned (rolled back to 3w on 2026-09-21) · **Date:** 2026-09-16 · **Deciders:** Seom88 · **Related:** [ADR-015](015-lean-cpu-sizing-homelab-vs-datacenter.md)

> **Historical outcome:** trial reverted. 2w saved some RAM but no meaningful energy saving, and the extra RAM is not needed right now. The later single-node migration in [ADR-019](019-single-node-bare-metal-migration.md) supersedes this topology; the 3-worker configuration below is historical and is not the current cluster state.

Run prod on 2 workers instead of 3 to save resources. ADR-015 covered CPU sizing; this ADR covers topology and HA only.

## Quick path

1. Deploy prod with 2 worker nodes: Vault at 1 replica, `longhorn-prod` StorageClass at 2 replicas.
2. Verify: ArgoCD sync waves 0 to 1 go healthy, Vault is unsealed, Longhorn volumes show 2 replicas Healthy.
3. Soak on 2 workers; promote this ADR to Accepted only after the soak passes. Roll back by reverting replicas to 3 and re-balancing Longhorn.

## Details

| Topic | Decision |
|---|---|
| Goal | Reduce prod from 3 workers to 2 workers to save energy and capacity on the homelab. Trial only until soak evidence is in. |
| Vault (`platform/vault/values.yaml`) | `server.ha.replicas: 1` (was 3). `ha.enabled: true` and `raft.enabled: true` are kept so the Raft storage backend and config shape are unchanged. Injector stays at 2 replicas. |
| Longhorn (`platform/longhorn/templates/storageclass.yaml`) | `longhorn-prod` `numberOfReplicas: "2"` (was `"3"`). Required: `platform/longhorn/values.yaml` already has `defaultReplicaCount: 2` with `allowVolumeCreationWithDegradedAvailability: false`, so a `"3"` StorageClass could never provision on 2 nodes. |
| Why Longhorn 2 works | Hard anti-affinity needs 2 distinct nodes, which 2 workers satisfy. On loss of 1 node, volumes run degraded but read-write from the surviving replica. |
| Vault 1 tradeoffs | No HA: a restart means Vault downtime. Autounseal (`*/2` schedule) auto-heals the unseal after restarts. Single-PVC risk: the one Vault data PVC is a single point of failure — backups (ADR-009) are the recovery path. |
| Out of scope | ADR-015 (CPU sizing) is unchanged. `platform/longhorn/values.yaml` and `values-dev.yaml` are untouched. No refactoring. |

## Checklist

- [ ] `helm lint` and `helm template` pass for `platform/vault` and `platform/longhorn`.
- [ ] ArgoCD sync waves 0 to 1 report healthy on a 2-worker cluster.
- [ ] Vault is unsealed after sync (autounseal healed it or manual unseal done).
- [ ] Longhorn volumes show 2 replicas, status Healthy.
- [ ] Node drain test: drain one worker, confirm volumes stay read-write (degraded) and Vault recovers.
- [ ] Soak period completed before marking this ADR Accepted.

## Rollback

1. Revert `server.ha.replicas` to `3` in `platform/vault/values.yaml`.
2. Revert `numberOfReplicas` to `"3"` in `platform/longhorn/templates/storageclass.yaml`.
3. Sync via ArgoCD and let Longhorn re-balance replicas across 3 workers.

## Next step

Closed — rolled back per the steps above (Vault `replicas: 3`, `longhorn-prod` `"3"`). No soak, no accept.
