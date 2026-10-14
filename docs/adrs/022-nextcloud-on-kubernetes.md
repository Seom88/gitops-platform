# ADR-022: Nextcloud on Kubernetes — Dedicated CNPG Cluster, Shared Valkey, Per-App Ingress

**Status:** Accepted · **Date:** 2026-10-10 · **Deciders:** Seom88 · **Related:** [ADR-014](014-cilium-cni-and-identity-networkpolicies.md) (zero-trust policies), [ADR-015](015-lean-cpu-sizing-homelab-vs-datacenter.md) (deprecated 2026-10-10), [ADR-018](018-per-app-tailscale-ingress.md) (per-app ingress), [ADR-019](019-single-node-bare-metal-migration.md) (single node), [ADR-021](021-shared-valkey-cache-service.md) (shared cache)

## Context

The user asked for Nextcloud on the homelab cluster: files, calendar, contacts and sync clients, exposed only through the tailnet. The substrate already has every moving part this needs — the CloudNativePG operator with two production clusters, the shared Valkey cache from ADR-021 (built explicitly with nextcloud as its second consumer), per-app Tailscale Ingresses, and the Longhorn encrypted storage class. This ADR records how those pieces are wired for nextcloud and which upstream chart form was chosen.

## Decision

**`apps/nextcloud` (wave 6, `sync-only`): upstream chart `nextcloud/nextcloud 9.4.0` (appVersion 35.0.1, apache flavor) with first-party templates for the database, the network policies, and the ingress — the same split immich uses.**

- **Database: dedicated CNPG cluster `nextcloud-database`** — 2 instances, `ghcr.io/cloudnative-pg/postgresql:18.6-system-trixie` (the exact image immich and grafana already run), PVC 3Gi `longhorn-cnpg`. PostgreSQL 18 is on Nextcloud's recommended list (NC docs: *"PostgreSQL 14/15/16/17/18 (recommended)"*), so there is no reason to carry a second Postgres major version in the cluster.
- **Bootstrap: `initdb` today; recovery templated and gated off.** `.spec.bootstrap` is WRITE-ONCE in CNPG — the operator webhook rejects a cluster that names two bootstrap methods — so the recovery branch follows the `grafana-database` precedent: gated on `.Values.recovery.enabled`, with `externalClusters` + `compare-options` ignoring the inert `recoveryTarget`. A future PITR flips the flag and the cluster is recreated from its barman archive; it can never be "added" to an initdb cluster in place.
- **Backups: same shared bucket, own prefix.** Barman WAL archiving + daily `ScheduledBackup` to `s3://cnpg-db-backups/nextcloud/` on RustFS, retention 30d, `cnpg.io/skipEmptyWalArchiveCheck: "enabled"` (the immich 2026-10-05 wedge), `plugins` declared whenever `backup.enabled` and deliberately **not** gated on the recovery flag (the 2026-10-08 grafana outage).
- **Cache + file locking: the shared Valkey, redis `dbindex: 1`.** immich's Bull queues own db0; nextcloud gets db1 via a custom `redis.config.php` (the chart only renders redis settings from `REDIS_HOST*` env and has no dbindex knob). No `requirepass` — the same accepted trade-off as ADR-021: isolation by Cilium, not by a shared password with no distribution mechanism. `consumers` in `platform/valkey/values.yaml` gains `nextcloud`, which is the entire ingress surface.
- **Data: PVC 8Gi `longhorn-encrypted`**, chart default `Recreate` strategy (RWO volume). Same class as immich-library because these are personal files; 8Gi is a starting point (Longhorn expands volumes online).
- **Exposure: per-app Ingress `nextcloud.lonk-mirfak.ts.net`** (ADR-018), `phpClientHttpsFix.enabled: true` because TLS terminates at the tailscale proxy and Nextcloud must generate `https://` URLs behind it.
- **Resources:** requests 200m/1Gi, limits 1500m/2Gi (+ cron sidecar 50m–200m/128–256Mi), sized when the node had ~10.6Gi free. The node now reports ~31 GiB allocatable with ~12.5 GB headroom (ADR-019 amendment 2026-10-10), and these numbers stay because no throttling or OOMKill evidence justifies changing them. The lean-by-watts rule they were sized against (ADR-015) is deprecated as of 2026-10-10; sizing authority is now measurement.
- **Postgres role: plain owner.** No extensions (immich needs vchord/vector; nextcloud needs none), so no `managed.roles`, no `Database` CR, no superuser. Postgres minor upgrade path stays clean.
- **The app secret flow reuses the house pattern:** CNPG generates `nextcloud-database-app` (keys `host/dbname/username/password` → the chart's `externalDatabase.existingSecret`), admin credentials come from a namespace-local SOPS secret `nextcloud-admin`, and the Deployment is delayed to wave 2 by `deploymentAnnotations` so both exist before it is applied.

## Alternatives Considered

| Option | Tradeoff | Verdict |
|---|---|---|
| Bitnami PostgreSQL subchart (bundled in the upstream chart) | Second database operator in one cluster, no WAL archiving / barman parity, breaks the single DB story | Rejected — CNPG is the house DB, with a working backup/restore story |
| Dedicated Valkey/Redis per app | Clean failure domains, but +1 image, +1 Deployment, +1 policy set for a cache whose loss is degradation, not data loss | Rejected — the ADR-021 model (shared instance, per-consumer policy, db index) fits a homelab |
| `fpm` + `nginx` two-container chart mode | One more image and readiness surface to pin and scan | Rejected for now — single-user load does not justify it; the chart keeps the knobs if that changes |
| SQLite (chart default) | Zero ops, no concurrency guarantees for sync clients | Rejected — sync clients + web UI on SQLite is a data-integrity coin flip |
| SeaweedFS S3 as primary storage | Bulk files off the host disk | Deferred — files start on the Longhorn PVC; revisit when the volume crosses the size the node can absorb |

## Consequences

### Positive

- One app file tree mirrors immich: waves, PodMonitor mirror, SOPS per-namespace secrets, and the Barman model all reuse proven machinery.
- Nothing new is introduced operationally: no new operator, no new major Postgres version, no new cache instance.
- The recovery path is pre-declared: the archive, the plugin, and the flag exist from day one, so a restore is a values change, not an archaeology project.

### Negative

- Repo grows to 12 first-party charts / 11 with network policies / 11 namespaces — roadmap, CHANGELOG and the deep-dive docs are updated to match.
- Single node (ADR-019): 2 CNPG instances give quorum but no node-HA; a node failure still takes the app down. Accepted posture, restated, not changed.
- Valkey is now a shared failure domain for immich and nextcloud. Cache loss degrades both (queues drain, file locking falls back to the DB), it destroys nothing.
- The admin password and the backup credentials are namespace-local SOPS secrets that must be encrypted **before commit** (they ship as placeholders in `apps/nextcloud/sops/`).

## Verification

- `helm dependency build` + `helm lint` + `helm template` (apps/nextcloud): 15 documents; image digest-pinned; DB env resolves to `secretKeyRef nextcloud-database-app {host,dbname,username,password}`; Service 8080 → pod 80; Ingress backend `nextcloud:8080`; `redis.config.php` pins `dbindex: 1`; Deployment carries `sync-wave: "2"`; CNPG renders `initdb` + plugin + `skipEmptyWalArchiveCheck` + 3Gi `longhorn-cnpg` + the mirrored PodMonitor (operator `enablePodMonitor` set false — deprecated upstream, mirror carries the `release: monitoring` label).
- `kubectl apply --dry-run=server` on all 15 documents (namespace-remapped to an existing one): accepted by the API server.
- `just validate-images` / `validate-yaml` / `validate-json`: OK. The nextcloud image joins the fail-closed Trivy list; Renovate gains a manager for the inline image map so tag+digest bump together.
- Live smoke after sync (owner checklist): pod 1/1, PVC `Bound`, `nextcloud-database-app` secret created, `valkey-cli -n 1 DBSIZE` > 0 after first login, HTTPS reachable at `nextcloud.lonk-mirfak.ts.net`, ScheduledBackup succeeds on its first run.

## References

- ADR-021 (`021-shared-valkey-cache-service.md`) — the shared cache this consumes on db 1
- ADR-018 (`018-per-app-tailscale-ingress.md`) — the ingress pattern
- `docs/rustfs-iam.md` — the manual bucket/key model behind the backups
- upstream chart: <https://github.com/nextcloud/helm> (9.4.0 / appVersion 35.0.1)
- CloudNativePG bootstrap/recovery docs — `initdb` vs `recovery`, `.spec.bootstrap` write-once semantics
