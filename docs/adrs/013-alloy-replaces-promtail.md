# ADR-013: Grafana Alloy Replaces Promtail for Loki Log Collection

> **Amendment (2026-10-13).** The S3 backend is now external RustFS (`rustfs.lonk-mirfak.ts.net`, bucket `loki`); the SeaweedFS endpoint cited below (`seaweedfs-s3.seaweedfs.svc:8333`) is the pre-removal layout (see commit 0759031 and ADR-024).

**Status:** Accepted · **Date:** 2026-09-01 · **Deciders:** Seom88 · **Related:** [ADR-012](012-single-host-cluster-gateway.md)

## Context

Loki was deployed as `SingleBinary` (`loki 7.3.0`, gateway `ClusterIP :80`, S3 backend `seaweedfs-s3.seaweedfs.svc:8333`, buckets `loki-chunks`/`loki-ruler`, `auth_enabled: false` with `X-Scope-OrgID: fake` quirk) under `platform/monitoring` alongside `kube-prometheus-stack 88.6.1`, but without a log shipper. Grafana Explore → Loki returned empty results: Loki ingested nothing because no agent was forwarding pod logs to `http://monitoring-loki-gateway.monitoring.svc.cluster.local/loki/api/v1/push`.

Promtail is Grafana's legacy log shipper. Since 2024 it is in **maintenance mode** — Grafana announces no new features, only security/bug fixes, and directs all new deployments to Grafana Alloy ([Promtail deprecation notice](https://grafana.com/docs/loki/latest/fundamentals/getting-started/)). Continuing with Promtail would mean adopting a deprecated component at day one.

Requirement: a single, stateless agent that tails all pod logs cluster-wide and pushes to the existing SingleBinary Loki gateway with the required `X-Scope-OrgID: fake` header, without hostPath mounts, PVCs, or duplicated shippers.

## Decision

**Grafana Alloy (`alloy 1.12.1`, app `v1.19.2`) as DaemonSet, via Kubernetes API discovery. One shipper, no Promtail.**

- Add `alloy` dependency to `platform/monitoring/Chart.yaml` (`version: 1.12.1`, `repository: https://grafana.github.io/helm-charts`, app `v1.19.2`) alongside `loki 7.3.0` and `kube-prometheus-stack 88.6.1`.
- Configure Alloy in `platform/monitoring/values.yaml` under `alloy.alloy.configMap.content` (River syntax):
  ```river
  logging { level = "info" format = "logfmt" }

  discovery.kubernetes "pods" { role = "pod" }

  loki.source.kubernetes "pods" {
    targets    = discovery.kubernetes.pods.targets
    forward_to = [loki.write.grafana_loki.receiver]
  }

  loki.write "grafana_loki" {
    endpoint {
      url = "http://monitoring-loki-gateway.monitoring.svc.cluster.local/loki/api/v1/push"
      headers = { "X-Scope-OrgID" = "fake" }
    }
  }
  ```
- Run as `controller.type: daemonset` — one Alloy per node so every node's pods are tailed without gaps. A `Deployment` (single replica) would miss logs from pods on other nodes and require hostPath sharing; DaemonSet is the correct topology for log collection.
- Use `loki.source.kubernetes` (API-based discovery) instead of `loki.source.file` with `mounts.varlog` / `mounts.dockercontainers` hostPath mounts. API discovery needs no `/var/log` or `/var/lib/docker` mounts, no privileged hostPath, and follows the Kubernetes API as source of truth for pod metadata and labels.
- Stateless operation: WAL disabled by default, working dir `/tmp/alloy` is ephemeral (`emptyDir`). No PVC, no `persistence` — Alloy recovers from Loki/gateway availability, no local state to manage or back up.
- RBAC auto-created by the Alloy chart (`serviceAccount.create: true`, `rbac.create: true` defaults): `ServiceAccount` + `ClusterRole`/`ClusterRoleBinding` granting `get/list/watch` on `pods`, `nodes`, `nodes/proxy` for `discovery.kubernetes`. No manual `ClusterRole` manifest required.
- Single shipper invariant: Alloy is the only log forwarder. No Promtail DaemonSet alongside it — avoids duplicate ingestion and double storage cost in S3.

## Alternatives Considered

| Option | Tradeoff | Verdict |
|---|---|---|
| Promtail (`grafana/promtail` chart, DaemonSet, `hostPath: /var/log/pods`) | Maintenance mode since 2024, no new features, Grafana recommends Alloy for all new installations; hostPath mounts and positions file on PVC/hostPath add operational surface | Rejected — deprecated upstream |
| Fluent Bit (DaemonSet, `tail` + `loki` output plugin) | Mature and lightweight, but not Grafana-native: LogQL label alignment, Loki push API, and `X-Scope-OrgID` header require extra plugin config; second observability agent paradigm (separate from Grafana stack); no OTel convergence benefit | Rejected — extra complexity, no Grafana-native alignment |
| Alloy as Deployment (single replica, API discovery) | Fewer pods, but incomplete coverage — API discovery still works, but log volume funnels through one pod, single point of failure, no per-node locality | Rejected — DaemonSet is the canonical log-collection topology |

## Consequences

### Positive

- Future-proof: aligns with Grafana's recommendation; Alloy is the actively developed successor to Promtail.
- OTel-ready: same binary can collect logs, metrics, and traces (`otelcol` components) without adding Fluent Bit / OpenTelemetry Collector later — single agent convergence.
- No host mounts, no storage: no `hostPath` for `/var/log`, no PVC/WAL — stateless DaemonSet, ephemeral `/tmp/alloy`, simpler security posture and backup story.
- Grafana-native pipeline: `discovery.kubernetes` → `loki.source.kubernetes` → `loki.write` maps directly to Loki labels and LogQL; `X-Scope-OrgID: fake` header matches existing `auth_enabled: false` quirk used by Grafana datasource (`platform/monitoring/values.yaml` `kube-prometheus-stack.grafana.additionalDataSources`).
- One shipper, no duplication: avoids double ingestion and S3 cost.

### Negative

- River config syntax learning curve — Alloy uses `river` (HCL-like) instead of Promtail's YAML `scrape_configs`; team must learn `discovery.*` / `loki.*` component model.
- Slightly larger image than Promtail (Alloy bundles OTel + Prometheus + Loki components even when only logs are used) — negligible at homelab scale, but higher baseline memory per node.
- Chart update cadence: Alloy releases faster than Promtail; `platform/monitoring/Chart.yaml` `alloy: 1.12.1` must be kept current to track `v1.19.x` fixes.

## Verification

- `helm template platform/monitoring | grep -q "kind: DaemonSet"` and `grep -q "grafana/alloy"` — Alloy DaemonSet rendered, no Promtail `DaemonSet`.
- `helm template platform/monitoring | grep -q "discovery.kubernetes.*pods"` and `grep -q "loki.source.kubernetes"` — River pipeline present.
- `helm template platform/monitoring | grep -q "monitoring-loki-gateway.monitoring.svc.cluster.local/loki/api/v1/push"` and `grep -q "X-Scope-OrgID"` — gateway URL + header match Loki datasource quirk.
- `helm template platform/monitoring | grep -q "mounts.varlog"` → no output (no hostPath varlog mounts); `grep -q "kind: PersistentVolumeClaim"` for Alloy → no output (stateless, no PVC).
- `helm lint platform/monitoring` + `just validate` pass.
- Live: `kubectl get daemonset -n monitoring monitoring-alloy` → desired == ready; `kubectl logs -n monitoring ds/monitoring-alloy | grep "loki.write"` no errors.
- Grafana Explore → Loki datasource → `{namespace="monitoring"}` returns Alloy-forwarded logs (previously empty).

## References

- Grafana Alloy docs: https://grafana.com/docs/alloy/latest/ — Alloy as OTel-compatible collector, `loki.source.kubernetes` component
- Promtail deprecation / maintenance mode: https://grafana.com/docs/loki/latest/fundamentals/getting-started/ and https://grafana.com/docs/loki/latest/send-data/promtail/ (banner: Promtail is in maintenance mode, use Alloy)
- `platform/monitoring/Chart.yaml` — `alloy: 1.12.1` (app `v1.19.2`), `loki: 7.3.0`, `kube-prometheus-stack: 88.6.1`
- `platform/monitoring/values.yaml` — `alloy.alloy.configMap.content` (River pipeline), `alloy.controller.type: daemonset`, `loki.gateway.enabled: true`, `loki.loki.auth_enabled: false` + `X-Scope-OrgID: fake`
- Loki push API: `http://monitoring-loki-gateway.monitoring.svc.cluster.local/loki/api/v1/push`
