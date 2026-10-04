# ADR-020: Full Velero Backup + LAN S3 Data Plane (v2 DR)

**Status:** Proposed · **Date:** 2026-10-04 · **Deciders:** Seom88 · **Related:** [ADR-009](009-vault-dr-and-velero-backup.md), [Cluster recovery](../cluster-recovery.md)

> **Outcome (proposed):** Velero backs up everything (objects + data, including system Secrets such as the `tailscale` namespace) so DR order becomes Velero-first → ArgoCD sync on top, with no manual cleanups; and the S3 data plane moves from the Tailscale egress proxy to the LAN, taking restores from hours to minutes.

## Context

The Oct 2026 immich pilot proved the current DR works but exposed its costs:

- The ArgoCD fight (CNPG killing pods mid-restore) forces a GitOps freeze; stale `spec.volumeName` forces fresh provisioning; the manual kopia-in-a-pod detour traded one solved problem for three new ones (endpoint format, secret hygiene, node inotify limits).
- The pod-based Tailscale egress proxy (`tailscale/ts-s3-egress`) cannot hole-punch, so all S3 traffic relays via DERP(Miami) at ~1 MB/s — a 6.1 GB library restore takes ~2 h. The laptop on the same tailnet gets `direct`; the cluster never will from inside CNI NAT.
- Fresh clusters re-register Tailscale devices because the operator keeps identity in kube Secrets (`tailscale` namespace), and the `daily-full` schedule only backs up `pvc/pv/pods` — so stale devices pile up and are deleted by hand.

## Decision

### 1. Full backup (objects + data)

Extend `daily-full` beyond `pvc/pv/pods` to full objects including system Secrets (notably the `tailscale` namespace). DR order becomes: install Velero → restore everything → ArgoCD syncs on top of restored state. Restored operator Secrets mean Tailscale devices resume instead of duplicating — no manual device cleanup.

Kept exclusions: `vault` (Raft re-bootstrap, never restore), DB *data* (Barman PITR; DB *objects* already dropped by the `cnpg.io/cluster` `DoesNotExist` selector), ArgoCD control plane (Git is source of truth).

Known cost, accepted consciously: backup object tarballs carry Secrets base64-plain (kopia encryption covers volume *data*, not objects). Acceptable against our own RustFS; not to be replicated to third-party storage without object-level encryption.

### 2. LAN S3 data plane

Point the BSL `s3Url` at a LAN endpoint for RustFS instead of `https://rustfs.lonk-mirfak.ts.net` through the egress proxy. Tailnet stays for control/remote access; gigabytes go over the wire. Expected gain: DERP-bound ~1 MB/s → LAN line rate; the 6 GB restore drops from ~2 h to minutes, and the 02:00 backup stops taking all night.

Prerequisites (mechanical, post-restore only — never rewire mid-flight): nodes reach TrueNAS over LAN (same 192.168.2.x fabric); the LAN name/IP in RustFS cert SANs; LAN resolution in DNSConfig; LAN CIDR opened in the egress CiliumNetworkPolicy. Tailnet FQDN stays documented as fallback.

## Consequences

- DR becomes a two-step runbook (Velero restore, ArgoCD sync) with no per-app surgery and no device pruning.
- Backup size grows (all objects); restore time shrinks (LAN) — net RTO collapses.
- Secret material now rests in the bucket: bucket access = cluster access. RustFS IAM stays tight; no off-site copies without encryption.
- LAN dependence: restores require LAN adjacency to TrueNAS (true for all planned DR targets: same rack, VM host, spare PC).

## Rollback

1. Revert `includedResources`/selector changes in `platform/velero/values.yaml` (back to `pvc/pv/pods` + CNPG exclusion).
2. Revert BSL `s3Url` to the tailnet FQDN.
3. Re-add the step 5.0 DB-shell cleanup and manual device pruning to the runbook (current doc state).

## Next steps

- [ ] Pilot full-object backup on one schedule run; measure size delta.
- [ ] Restore-drill into `verify-*` namespace from the full backup (dev verify-only cluster).
- [ ] iperf nodes→TrueNAS over LAN to confirm headroom before rewiring.
- [ ] RustFS cert SAN + DNS + Cilium policy for the LAN endpoint.
- [ ] Flip BSL to LAN; keep tailnet FQDN as documented fallback.
- [ ] Update [Cluster recovery](../cluster-recovery.md) to Velero-first order once proven.
