# ADR-025: Solar-Energy-Aware Operations (Measurement First)

**Status:** Accepted · **Date:** 2026-10-18 · **Deciders:** Seom88 · **Related:** [ADR-019](019-single-node-bare-metal-migration.md), [ADR-020](020-full-velero-backup-lan-s3.md), [ADR-024](024-remove-seaweedfs-external-rustfs-s3.md)

> **Outcome:** the cluster gains an energy-budget constraint and an energy-observability layer (Kepler), the daily full backup moves out of the battery-deficit window and into the solar peak, and host-level energy work is explicitly scoped OUT of this repo to the infra repo. Measurement happens before any further tuning.

## Context

The single node ([ADR-019](019-single-node-bare-metal-migration.md), amended 2026-10-18) runs on a ThinkCentre M920q (i7-8700T, 6C/12T, 32 GiB, Intel UHD 630 iGPU) that also hosts the TrueNAS VM (6 GiB / 6 vCPU, RustFS S3 endpoint, two physical 2.5" HDDs). Power comes from a **200W solar panel + 768Wh battery** in Bogotá:

- The panel has a hard shadow cutoff at **15:30 local** (a neighbour's building; the panel cannot be moved).
- The battery ends the day at **~85%** instead of 100% — a deficit of roughly **100–115Wh/day**, i.e. **~8–10W of average draw** to eliminate (or shift into the solar window).
- No budget for a wall-power meter (smart plug) right now.
- ADR-019's amendment retired "resource savings" as a sizing motivation: **future sizing is evidence-driven, never thrift**. Energy autonomy from the solar system is a NEW, legitimate driver, recorded here as the motivating constraint — the *method* remains the same: measure, decide, verify.

Bogotá is a poor insolation site and shading already truncates the generation day, so hardware-side additions are off the table: the axis of action is **consumption** and **when** the cluster spends its watts.

## Decision

### 1. Energy observability first (in-cluster, this repo)

Deploy **Kepler** (CNCF; Kubernetes-based Efficient Power Level Exporter) as a DaemonSet, wave 3, namespace `kepler` (`platform/kepler/`, vendored chart `0.12.0`):

- Reads RAPL from the host's Intel package: **CPU cores + DRAM + iGPU + uncore** watt readings, attributed per pod/node into Prometheus.
- Wraps the upstream chart with lean defaults: `log.level: info`, kube pod-attribution on (`pollInterval: 30s`), ServiceMonitor scraped by kube-prometheus-stack (`release: monitoring` label, 30s interval), resource requests 50m/64Mi — the meter must be a negligible consumer of the budget it measures.
- **Known accuracy caveats** (documented, not blocking): independent work (KubeWatt, 2025) questions Kepler's *per-container* attribution accuracy; node-level totals exported via RAPL are the trusted layer here, pod-level numbers are directional.
- **RAPL does not measure**: physical disks, fans, PSU conversion loss, the TrueNAS VM as a hypervisor guest is CPU-attributable, inverter standby, or ANY network gear outside the box. The battery SoC remains the daily ground truth; wall-power measurement is a future item when budget allows.

### 2. Solar-window scheduling (in-cluster, this repo)

**Velero `daily-full` moves from `02:00` (UTC in the Velero server pod → 21:00 America/Bogota) to `18:00` (UTC → 13:00 Bogotá)** — the centre of the fixed-panel output peak, before the 15:30 shadow cutoff. The backup's kopia CPU/IO burst now lands on panel power instead of the night battery reserve, exactly when the household's consumption peaks. RPO is unchanged (max 24h between fulls); the *distribution* improves: a crash after 13:00 loses less than 24h of changes, and the night is no longer touched.

**Kepler's own tradeoffs made explicit** (`platform/velero/values.yaml`, schedule comment): the vendored Velero Schedule CRD (chart 12.2.1) does **NOT** declare `spec.timeZone` (structural CRD → unknown fields pruned), and the subchart renders no timeZone, so the cron expression is interpreted in the Velero server pod's timezone — container default UTC. This must be verified on the first deployment (`kubectl -n velero exec deploy/velero -- date +%Z`).

### 3. Explicitly rejected, and why

- **kube-green**: designed for off-hours scale-down of dev/preview workloads. This is a residential homelab whose *usage peak is at night* — sleeping pods at 20:00 would suspend work during peak demand, and pod churn itself burns watts. The only night-scheduled task (Velero daily-full) was fixed directly at its source; an operator just to suspend CronJobs adds a controller to the energy budget to solve a one-line config.
- **GPU power limiting / scale-to-zero (nvidia-smi, KEDA GPU scalers)**: prior research targets NVIDIA dGPUs. This node has the Intel UHD 630 iGPU — ~1–3W idle inside the RAPL package, no NVML, no meaningful lever. Immich ML stays 1 replica on OpenVINO.
- **Node suspend/hibernate**: a k3s single-node with resident services (and an afternoon-heavy household usage profile) cannot hibernate.
- **Consolidating a "companion host"**: it does not exist — a factual error now corrected (ADR-019 amendment 2026-10-18). There is one machine; TrueNAS is already a VM on it.

### 4. Out of scope for this repo (host-level, → infra repo)

Hardware/environment work is recorded here so it is not lost, but implemented in the infra repo with its own verification:

1. **TuneD/PowerTOP host profile** — `powertop2tuned -e`, deep C-states, `powersave` governor, ASPM; watch CPU throttling like any performance change (ADR-019 evidence clause).
2. **SATA link power management** (`min_power`) — careful with the two 2.5" HDDs; verify with the TrueNAS VM stopped before trusting.
3. **TrueNAS VM sizing re-check** — the operator reports that fewer vCPUs *increased* consumption; unverified. Re-test under Kepler + RAPL evidence before any re-assignment; the 6GB/6vCPU grant stands until measured otherwise.
4. **2.5" HDD idle policy** in TrueNAS (ZFS: periodic txg writes fight spin-down; assess honestly rather than assuming).
5. **Inverter standby consumption** — often 5–20W; if the deficit survives everything else, this is the prime suspect.
6. **k3s control-plane churn** (`leader-elect=false` on single-node, disable unused packaged components) — small but real.
7. **Wall-power metering** when budget allows (completes RAPL's blind spots); meanwhile the **battery SoC log is the daily ground truth** and a charge-controller scrape into Prometheus is the open follow-up.

## Consequences

### Positive

- The daily full backup consumes its watts during panel output; the night deficit loses its largest discretionary load.
- A first-class energy telemetry surface in Prometheus/Grafana — ADR-019's "evidence-driven" clause finally has its instrument.
- The battery-deficit budget (~8–10W average) is now a *named* constraint every future sizing decision can check against.

### Negative

- Kepler produces pod-level power attribution of debated accuracy — treat per-pod rankings as directional until validated against node totals.
- The midday full overlaps potential daytime usage of the cluster (Immich ingest, Nextcloud) — minor; both are read-heavy and the panel covers the CPU burst.
- The backup's cron-TZ dependence on the Velero server pod is now load-bearing; a future chart bump that adds native `timeZone` support should adopt it explicitly (see verification).

## Verification

- `helm template kepler platform/kepler -n kepler` renders exactly: Namespace(implicit via Argo), ServiceAccount, ConfigMap, ClusterRole, ClusterRoleBinding, Service, DaemonSet, ServiceMonitor (`release: monitoring`, 30s), and the three `CiliumNetworkPolicy` objects (DNS; kube-apiserver 443/6443 + kubelet 10250 egress; monitoring scrape + host probes on 28282). The policy flows are pinned by `./scripts/check-kepler-policy.sh` (CI + `just validate-kepler`), because the apiserver egress is load-bearing: Kepler discovers the kubelet endpoint from the Node object at startup and exits(1) otherwise.
- `helm template velero platform/velero --set s3.tailnetFqdn=<fqdn> -n velero` renders the Schedule with `schedule: "0 18 * * *"`.
- After ArgoCD sync: `kubectl -n kepler get ds kepler` ready; `curl svc/kepler:28282/metrics | grep kepler_node_cpu_watts` from in-cluster; a Grafana panel on `kepler_node_*` watts series.
- Reset TZ check: `kubectl -n velero exec deploy/velero -- date +%Z` → expect `UTC`; if not, re-derive the Bogotá hour in the schedule comment.
- Ground truth after one week: battery evening SoC trend vs the 85% baseline, and the Kepler daily Wh integral for the 18:00 UTC backup window.
