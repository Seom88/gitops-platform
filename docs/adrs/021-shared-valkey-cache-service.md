# ADR-021: Shared Valkey Cache Service

**Status:** Accepted · **Date:** 2026-10-10 · **Deciders:** Seom88 · **Related:** [ADR-014](014-cilium-cni-and-identity-networkpolicies.md), [ADR-006](006-app-health-and-vault-ordering.md)

> **Outcome:** Valkey moves out of the immich subchart into a dedicated `platform/valkey` Application in its own `valkey` namespace (wave 2). immich consumes `valkey.valkey.svc.cluster.local` today; nextcloud joins the `consumers` list when its Application lands. No `requirepass`: isolation comes from Cilium default-deny `CiliumNetworkPolicy` per ADR-014.

## Context

The immich chart (0.13.4) bundles a Valkey subchart that renders `immich-valkey` — a `Deployment`, `Service`, and `ServiceAccount` — inside the `immich` namespace. That layout has two problems:

1. **Single consumer.** As soon as nextcloud (or any other app) needs a cache, it gets a second copy of the same stateful container, in its own namespace, with its own lifecycle, its own values, and its own policy surface — N Valkey deployments to patch and scan.
2. **Blast radius.** Valkey carries the intra-namespace policy slots (6379 in both the immich egress and ingress policies). Keeping a cache inside an application namespace couples the application's update cadence to a shared stateful service.

The repo already solves this shape for other platform capabilities: each shared dependency (SeaweedFS, CloudNativePG, monitoring) lives in `platform/` as its own chart, own namespace, own wave. Valkey was the last stateful service embedded in an app.

## Decision

Valkey becomes a first-party platform service. No authentication: no `requirepass`, no Secret, no TLS. The `valkey` namespace is reachable only from the consumer namespaces listed in `platform/valkey/values.yaml`, enforced by Cilium default-deny (ADR-014).

| What | Before | After |
|---|---|---|
| Valkey `Deployment` / `Service` / `ServiceAccount` | immich subchart, namespace `immich`, names `immich-valkey` | `platform/valkey` chart, namespace `valkey`, names `valkey` |
| Data volume | `emptyDir` (volatile) | PVC `valkey-data`, 1Gi `longhorn-encrypted` |
| Network exposure | Port 6379 open intra-namespace via immich policies | Dedicated `valkey-allow-*` policies; ingress 6379 restricted to the `consumers` list |
| immich wiring | Chart default `REDIS_HOSTNAME=<release>-valkey` | `REDIS_HOSTNAME=valkey.valkey.svc.cluster.local` on server + machine-learning |
| ArgoCD wave | Same app as immich (wave 5) | Wave 2, `wave-policy: healthy` (immich is wave 5) |

Two verified traps made the wiring non-trivial. The first one fails silently, so it is worth stating precisely:

- **The chart's shared `controllers` block is not overridable, and a wrong-level override is invisible.** The 0.13.4 chart ships `values.schema.json`, which rejects a `controllers` key inside the immich subchart values outright (`additional properties 'controllers' not allowed` — verified with `helm template` against 0.13.4). A `controllers:` block written at the top level of `apps/immich/values.yaml` is worse: it belongs to the *wrapper* chart — the subchart is aliased `immich:`, hence the `immich.immich` value shape — so it never reaches the subchart, is neither schema-checked nor template-rendered, and the app silently keeps the chart default `REDIS_HOSTNAME=<release>-valkey`. The only override that takes effect is per component (`immich.server.controllers.main.containers.main.env` and `immich.machine-learning.controllers...`), the same form the existing `DB_*` entries use.
- **Disabling the subchart does not disable its env defaults.** With `valkey.enabled: false` both the server and machine-learning containers still render `REDIS_HOSTNAME: immich-valkey` (the shared `controllers.main.containers.main.env` default, rendered from `{{ printf "%s-valkey" .Release.Name }}`). Overriding `REDIS_HOSTNAME` on both components is therefore mandatory, not cosmetic: without it the app points at a hostname that no longer resolves — the subchart `Deployment`/`Service` are pruned and the cross-namespace policy never existed.

## Tradeoffs

- **No authentication.** `requirepass` would need a Secret in the `valkey` namespace and the same credential material distributed into every consumer namespace — a pattern this repo deliberately avoids (the only cross-namespace Secret case is the CNPG Barman credential, duplicated by hand into two namespaces, ADR-020). Per-namespace Cilium isolation gives every namespace the same blast-radius separation a password would, and a cache holds no durable secret material. Accepted.
- **1Gi PVC on `longhorn-encrypted`.** The data is a rebuildable cache; the volume exists only to avoid cold restarts. `longhorn-encrypted` is the app volume class — `longhorn-cnpg` is reserved for databases. A 1Gi cache volume is cheap; an `emptyDir` was rejected because a restart would re-derive the thumbnail queue from the database anyway, and the restart cost is measurable.
- **Single replica, no PDB.** Cache data is disposable and `strategy: Recreate` is required by the RWO volume. HA of a cache adds Longhorn replica cost for zero user-visible benefit; the failure mode is a cold cache, not an outage.

## Changes

| File | Change |
|---|---|
| `platform/valkey/Chart.yaml` | New first-party chart, no dependencies (raw manifests) |
| `platform/valkey/values.yaml` | Digest-pinned image, `ciliumNetworkPolicy`, `consumers`, `persistence`, lean resources |
| `platform/valkey/templates/deployment.yaml` | `Deployment` valkey, `Recreate`, exec probes, PVC-or-emptyDir `data` |
| `platform/valkey/templates/service.yaml` | ClusterIP `Service` valkey, port `redis` 6379 |
| `platform/valkey/templates/service-account.yaml` | `ServiceAccount` valkey, token automount off |
| `platform/valkey/templates/pvc.yaml` | PVC `valkey-data`, gated on `persistence.enabled` |
| `platform/valkey/templates/cilium-networkpolicies.yaml` | `valkey-allow-dns` / `-egress` / `-ingress`; ingress generated from `consumers` |
| `gitops/templates/platform/02-valkey.yaml` | `Application` valkey, namespace `valkey`, wave 2, `wave-policy: healthy` |
| `apps/immich/values.yaml` | `valkey.enabled: false`; `REDIS_HOSTNAME` override on server + machine-learning |
| `apps/immich/templates/cilium-networkpolicies.yaml` | 6379 moved from intra-namespace to a dedicated `namespace: valkey` egress rule |
| `docs/roadmap.md`, `docs/customization-guide.md`, `docs/features-deep-dive.md` | Chart/netpol/namespace counts, wave listing, app tree |
| `CHANGELOG.md` | Unreleased entry for the shared service |

## Rollback

1. Revert `valkey.enabled: false` to `true` in `apps/immich/values.yaml` (subchart renders `immich-valkey` again).
2. Remove the two `REDIS_HOSTNAME` overrides, or point them back at `immich-valkey`.
3. Delete `gitops/templates/platform/02-valkey.yaml` and the `platform/valkey/` directory; ArgoCD prunes the `valkey` namespace Application and its resources.
4. Restore port 6379 to the intra-namespace lists in `apps/immich/templates/cilium-networkpolicies.yaml`.

The migratable data is a cache: no restore is required. immich rebuilds thumbnail and job state from the CNPG database.

## Next steps

- [ ] Add `nextcloud` to the `consumers` list in `platform/valkey/values.yaml` when the nextcloud Application lands (wave ≥ 3); no other change is needed — the ingress policy is generated from that list.
- [ ] Monitor cache hit behavior after the cut (Grafana/Hubble) and re-evaluate the 1Gi volume size if the volume fills.
- [ ] If a second cache ever needs credentials (a queue with durable semantics, not a rebuildable cache), revisit this decision — the Cilium-isolation argument is specific to rebuildable state.
