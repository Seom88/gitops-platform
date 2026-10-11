# ADR-015: Lean CPU Sizing in Prod, Full Sizing in Dev

**Status:** Deprecated (2026-10-10) · **Date:** 2026-09-14 · **Deciders:** Seom88 · **Related:** [ADR-012](012-single-host-cluster-gateway.md) (itself superseded by [ADR-018](018-per-app-tailscale-ingress.md)), [ADR-014](014-cilium-cni-and-identity-networkpolicies.md), [ADR-019](019-single-node-bare-metal-migration.md)

> **Deprecation (2026-10-10): premise retired, decision voided.**
> This ADR sized prod lean against a topology that no longer exists: three worker
> VMs, 22 CPUs, and a "every reserved millicore costs watts" energy constraint.
> The cluster is now a single bare-metal node (`aleph`, AlmaLinux 10.2, k3s
> v1.36.5) reporting **12 CPU and ~31 GiB allocatable RAM**; at rest it sits at
> 5.4 cores (45%) and ~19.9 Gi (62%), leaving roughly 6.5 cores and ~12.5 GB of
> headroom. The cluster is not resource-constrained, so the reason to be lean is
> gone.
>
> **Retired in full:** the "reserve as few millicores as possible to save power"
> rule and its justification. No sizing value in `platform/*/values.yaml` or in
> the app charts was changed by this deprecation.
>
> **What still applies:** only the mechanism this ADR happened to establish —
> the prod/dev value split (`values.yaml` base, `values-dev.yaml` overlay). That
> is a delivery concern, not a sizing decision, and it keeps working.
>
> **What replaces it:** evidence-driven sizing. A request or limit changes only
> on measured pressure — CPU throttling, OOMKills, or scheduling failures — and
> never on thrift, and never on "we have headroom now". Raising requests without
> that evidence consumes allocatable headroom for no benefit; the headroom itself
> is what protects the node, so consuming it is the opposite of safety.
>
> **Supersedes:** none · **Superseded by:** none. Retired without a replacement
> decision — sizing authority is now the measurement itself, which is what this
> ADR's own checklist already required. Live topology and numbers: ADR-019
> amendment 2026-10-10.

Prod (`platform/*/values.yaml`) carries lean CPU requests and limits measured on this energy-constrained homelab. Dev (`platform/*/values-dev.yaml`) carries full requests and limits so tests get rich metrics and catch throttling or OOM pressure before prod.

## Quick path

1. Deploying prod on the homelab → use `values.yaml` as-is; every reserved millicore costs watts.
2. Deploying dev → apply the `values-dev.yaml` overlay (ArgoCD does this automatically when `developmentApp.enabled` is true) for full headroom and dense metrics.
3. Verify no workload regressed: compare container CPU throttling and OOMKills before and after the switch.

## Details

### Why prod is lean

> Superseded by the deprecation note above — this section is kept as the record of why the numbers existed, not as guidance.

This homelab runs under a hard energy constraint: every reserved millicore keeps a CPU from sleeping and costs watts around the clock. Prometheus evidence at rightsizing time showed the cluster averaging 13–17% of 22 CPUs, with peaks of 40–47% driven almost entirely by Trivy scan bursts, and zero CPU throttling anywhere. That profile justified trimming idle reservations to the floor while keeping burst limits — a power and bin-packing optimization, not a performance one.

### Why dev is full

Dev exists to catch what lean prod would hide: starved compactors, throttled scan jobs, and bursty dashboard rendering. Full requests give each component scheduling headroom, full limits let bursts run unthrottled, and denser scrapes produce the metrics that make those problems visible. A failure that only appears under lean sizing is a prod surprise; dev's job is to surface it first.

### Prod vs dev CPU table

Prod is `platform/*/values.yaml` (lean homelab). Dev is `platform/*/values-dev.yaml` (full; catches pressure before prod). Memory is unchanged in both.

| Component | Prod (request / limit) | Dev (request / limit) | Why dev is higher |
|---|---|---|---|
| vault server | 250m / 1000m | 500m / 2000m | Raft quorum traffic plus unseal bursts spike far above the ~10m follower idle; dev keeps scheduling and burst headroom so quorum behavior is tested, not starved |
| prometheus | 150m / 800m | 500m / 1000m | TSDB compaction and WAL replay burst well above scrape steady state; dev feeds the compactor so head growth and disk usage stay visible |
| loki | 100m / 800m | 300m / 1000m | TSDB index churn and concurrent query bursts exceed the single-binary idle average; dev absorbs them for query testing |
| grafana | 80m / 500m | 200m / 1000m | Dashboard rendering bursts with concurrent viewers; idle is near zero but dev renders must never throttle while testing |
| alloy (per node) | 50m / 200m | 100m / 200m | Log tail fan-out scales with pod density per node; dev keeps the floor so log volume is never starved while testing |
| seaweedfs master / filer / s3 | 20m each (limits 500m) | 50m each (limits 500m) | RPC heartbeats and filer metadata bursts need a scheduling floor in dev; limits already cap spikes in both envs |
| seaweedfs volume | 30m (limit 1000m) | 100m (limit 1000m) | Disk IO bursts dominate volume CPU; dev keeps the floor while the generous limit never throttles engine IO |
| seaweedfs admin | 10m (limit 200m) | 20m (limit 200m) | Idle console; dev keeps the bin-packing floor |
| velero server | 100m / 300m | 200m / 500m | Backup and FsBackup IO burst far above the idle server steady state; dev keeps room for parallel volume backups |
| ts-gateway (nginx) | 25m / 300m | 100m / 400m | TLS termination plus proxied dashboard traffic burst under concurrent viewers; dev keeps headroom above the idle data plane |
| trivy-operator scans | 50m / 600m | 100m / 1000m | Scan jobs unpack image layers and drove the 40–47% cluster peaks; dev allows parallel scans without starving neighbors, prod keeps the tight cap so bursts throttle visibly at home first |
| longhorn `guaranteedInstanceManagerCPU` | v1 4 / v2 12 | v1 12 / v2 12 (upstream default) | Instance-manager pods drive engine IO on every node and take no CPU limit; v2 keeps dedicated cores for SPDK stability in both envs, v1 is trimmed in prod only where nodes are small and measured |

### Timers and scrapes

Prod keeps the long, wakeup-saving timers: autounseal `SLEEP_HEALTHY` 60s, Velero `backupSyncPeriod` 10m, ESO `refreshInterval` 5m, 60s Prometheus scrape/evaluation intervals plus the apiserver cardinality diet. Dev may use shorter scrapes and timers for richer metrics; no dev timer overrides are shipped with this ADR so chart defaults stay intact — add them only if a dev investigation needs denser data, and keep them out of prod.

### Out of scope

- Memory requests/limits are untouched: no memory pressure was observed.
- The Trivy 100% scan failures are a Cilium 1.20.1 `toFQDNs` TLS-breakage issue at the CNI layer, not a sizing problem; no CPU value fixes it.
- Cilium and Trivy egress policy is a separate track and unchanged by this ADR.

## Checklist

- [ ] `values.yaml` holds the prod column; `values-dev.yaml` pins the dev column for every row above.
- [ ] A fresh prod deploy on the homelab works with zero overlay files applied.
- [ ] Throttling or OOM pressure reproduces in dev first, never as a surprise in prod.
- [ ] Any future rightsizing updates both columns and this table together.

## Next step

If a workload shows CPU throttling or OOMKills in prod, reproduce it in dev first, then promote the fixed numbers to both columns and this table together.
