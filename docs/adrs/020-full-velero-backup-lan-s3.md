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

Extend `daily-full` beyond `pvc/pv/pods` to full objects including system Secrets (notably the `tailscale` namespace). DR order becomes: install Velero → restore everything → ArgoCD syncs on top of restored state. Restored operator Secrets mean Tailscale devices resume instead of duplicating — no manual device cleanup. Note this does **not** cover DB content: see the correction in the parking lot (a restored `Cluster` object replays its synced `initdb`).

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

## Parking lot (Oct 2026 — not decided, needs planning)

### Recovery environment

Idea: a dedicated `recovery` environment/overlay that points at prod backups,
restores DBs from Barman, then gets re-applied to point at prod without the
recovery stanza. Still unplanned. Constraints learned so far
(see [Cluster recovery §7](../cluster-recovery.md)): CNPG only honours
`bootstrap.recovery` on empty PGDATA (never in place), so the overlay still
needs a human `kubectl delete cluster` (operator drops the PVCs) before the
recreate; nothing may stay pinned in the synced path (a pinned recovery =
silent surprise restore, a missing one = empty DB — empty is the safer
failure). A separate non-auto-sync ArgoCD Application as a manual DR button
is the leading shape; an automatic PreSync hook was rejected (it would fight
selfHeal and can misfire on genuinely fresh installs with zero PVCs).

### DR bootstrap script (Oct 2026 — design, not implemented)

Instead of a transient recovery environment, a single DR script (local with
`kubeconfig` first, wrapped as a Job later) that bootstraps the minimum for
restores to work, then hands over to ArgoCD. Proposed order:

0. Prerequisite (assumed, not scripted): the cluster is provisioned — Cilium
   up, ArgoCD running, plus the Longhorn Application synced. Restores in step
   5 need the provisioner alive to create volumes; if Longhorn only arrives
   via ArgoCD in step 7 it is too late.
1. Tailnet DNS: apply `platform/ts-operator/templates/coredns-custom.yaml`
   (stub `lonk-mirfak.ts.net` → node `100.100.100.100`) so everything resolves
   RustFS before any operator needs it. Tailscale operator identity itself
   comes back via the full-object backup (Decision §1) — no re-registration.
2. `gitops/templates/platform/00-external-secrets.yaml` — ESO first, apps need
   secrets. Known gap: no Vault-backed ExternalSecrets exist yet (Vault is
   not deployed); when Vault returns, DR depends on Vault being bootstrapped
   first — flagged in the rollback/ADR-009 lane.
3. `gitops/templates/platform/-1-cloudnative-pg.yaml` — CNPG operator +
   barman plugin before any Cluster exists.
4. `gitops/templates/platform/00-velero.yaml` with the Velero SOPS values —
   BSL credentials in place, no separate SOPS bootstrap step.
5. Velero restores per namespace (`--wait`), DB namespaces excluded per the
   `cnpg.io/cluster` selector.
6. CNPG recoveries (grafana, immich, whatever comes next) via the
   `recovery.enabled` flag / recovery overlay, one at a time with health gate.
7. Apply `gitops/templates/root-prod-app.yaml` — ArgoCD adopts the restored
   objects and reconciles whatever is missing.

Each step gets a verification gate before the next (DNS resolves the tailnet
FQDN, ESO Healthy, Velero BSL `Ready`, restore `Completed`, Cluster healthy) —
a mid-run failure must not leave ambiguous state, and the script must be
idempotent on re-run.

Language: **Python** over bash. The flow is orchestration — retries, polling
JSON output from `kubectl`/`velero`/`barman`, partial-failure resume — and a
Python script with `subprocess` + `json` stays readable where bash degrades
into sed/awk on JSON. Bash remains fine for single-step glue
(`bootstrap/*.sh`); the DR coordinator crosses into script territory.

Vault stays out (own re-bootstrap, see [Cluster recovery](../cluster-recovery.md)
§Vault). Open: exact backup-ID parametrization (Velero backup name + Barman
`targetTime`), and where the script lives (`bootstrap/` vs `scripts/`).

Correction (Oct 2026): the full-object backup alone does **not** restore DBs.
A restored `Cluster` object carries whatever `bootstrap` stanza was synced at
backup time — normally `initdb` — so recreating it yields an **empty** database
even with backups present in the bucket. `initdb` never restores anything. DB
content therefore still needs `bootstrap.recovery` injected at recreate time
(`recovery.enabled` flag today; a script/overlay patch later), or the synced
stanza itself must be the recovery one (rejected: a permanently pinned recovery
is a silent surprise restore on every recreate). This is the immich incident
exactly: the cluster was recreated from `initdb`, so every Barman backup since
then is a valid backup of an empty database. ObjectStore windows still look
healthy (`firstRecoverabilityPoint` 2026-09-28, last successful 04:02 UTC) —
healthy backups, empty content. For immich the last real data is its native
SQL dump (`immich-db-backup-20260929T020000`, 30.8 MiB) still sitting in the
preserved `immich-library` PVC at `/data/backups/`; the in-app restore cannot
run it because CNPG does not hand the app user superuser
(`enableSuperuserAccess: false`), so a manual `psql` restore inside the primary
pod is the path.

### Should Velero carry DB data after all?

Evaluated, still **no**. A Velero FsBackup of live Postgres is crash-consistent
at best: WALs in flight, replica timelines diverging, and the restore replants
stale same-named pods + empty shells that the CNPG operator then reconciles
into a franken-state (observed in the immich pilot — the reason step 5.0
exists). Master/replica sync is exactly what Barman PITR already solves
(base backup + WAL replay to a consistent point). Duplicating DB bytes into
Velero buys a second, worse copy of the same data plus the operator fight.
Keep the split: Velero = volumes/files, Barman = Postgres. The real gap is
not *where* the bytes live but the GitOps ergonomics of triggering the
Barman restore — hence the recovery-environment idea above.
