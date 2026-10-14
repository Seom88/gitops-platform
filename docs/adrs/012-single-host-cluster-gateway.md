# ADR-012: Single-Host Cluster Gateway via Path-Based Ingress

> **Amendment (2026-10-13).** Every `seaweedfs*` path/Service referenced below is historical: the chart was removed and its S3 backend is now external RustFS.

**Status:** Superseded by [ADR-018](018-per-app-tailscale-ingress.md) (2026-09-22) · **Date:** 2026-09-02 · **Deciders:** Seom88 · **Supersedes:** part of [ADR-001](001-tailscale-ingress-placement.md) · **Related:** [ADR-010](010-tailscale-oauth-ci-generated.md), [ADR-011](011-tailscale-dns-np.md)

> **Superseded 2026-09-22 ([ADR-018](018-per-app-tailscale-ingress.md)):** the gateway is removed. Each app gets its own Tailscale `Ingress` + device at `/` root. This document is preserved as archive.

> **Amendment 2026-09-02 (ADR-014):** The current CNI is **Cilium 1.20.1** with enforced `CiliumNetworkPolicy` (ADR-014).

> **Amendment 2026-09-03:** chart renamed `ts-ingress` / `ts-operator`, namespace remains `tailscale`. Historical `platform/tailscale` / `platform/tailscale-operator` paths below are preserved as archive; new paths are `platform/ts-ingress` / `platform/ts-operator`.

## Context

The cluster historically exposed platform services via 7 separate Tailscale `Ingress` resources (`platform/tailscale/templates/platform/*ingress.yaml`), each with `ingressClassName: tailscale` and `tls.hosts: [service]`. Each `Ingress` creates a distinct Tailscale device, MagicDNS name (`grafana.lonk-mirfak.ts.net`, `argocd...`, etc) and Let's Encrypt certificate. At homelab scale this wastes tailnet devices (one per platform service) and burns weekly cert quota (50 unique / 5 duplicate).

Requirement: expose the entire platform through **one** tailnet device/hostname `my-cluster.lonk-mirfak.ts.net` with path routing (`/argocd`, `/grafana`, `/prometheus`, `/vault`, `/longhorn`, `/seaweedfs-s3`, `/seaweedfs-admin`) to avoid adding devices per service. The cluster currently uses Flannel CNI (no `NetworkPolicy` enforcement, but manifests remain Cilium-compatible); `coredns-patch` and `velero` Tailscale scoping stays unchanged.

Kubernetes constraint: an `Ingress` backend `Service` must be in the same namespace as the `Ingress`. A single cross-namespace `Ingress` fanning out to `argocd/argocd-server`, `monitoring/monitoring-grafana`, `longhorn-system/longhorn-frontend`, etc. is not valid. The Tailscale operator also rejects duplicate `spec.tls.hosts` across `Ingress`es in one cluster (`validateIngress: duplicate hostname`).

## Decision

**Single Tailscale Ingress + in-namespace NGINX gateway. Path-based, one device.**

- Keep Tailscale operator at wave `-1` `healthy` (no change).
- Replace 7 platform `Ingress`es with a **single** `Ingress` `my-cluster` in namespace `tailscale` (`ingressClassName: tailscale`, `tls.hosts: [my-cluster]`, `rules.http.paths: [{path:/ -> cluster-gateway:80}]`). This yields one device `my-cluster.lonk-mirfak.ts.net` and one cert.
- Deploy a lightweight NGINX `Deployment` + `Service` `cluster-gateway` in namespace `tailscale` (wave `4`, same chart) that reverse-proxies `/argocd`, `/grafana`, `/prometheus`, `/vault`, `/longhorn`, `/seaweedfs-s3`, `/seaweedfs-admin` to their respective cluster-internal `Service` DNS names (`argocd-server.argocd.svc.cluster.local:443`, `monitoring-grafana.monitoring.svc...`, etc). Routing table lives in a `ConfigMap` `cluster-gateway-nginx` mounted as `nginx.conf`.
- Gate per-service locations in `ConfigMap` with existing `.Values.{argocd,vault,grafana,prometheus,longhorn,seaweedfs.*}.enabled` toggles (same as before; now controls `location` blocks instead of separate `Ingress` files).
- Introduce `hostname` value (`my-cluster` / `dev-my-cluster` via `values-dev.yaml`) — hostnames differ per env, Service names do not.
- Simplify Service names: unify `gitops/templates/apps/*.yaml` `metadata.name` (remove `{{- if .Values.developmentApp.enabled }}-dev{{- end }}` except `root-prod-app.yaml` which keeps `gitops-dev`), and gateway upstreams now use unified DNS (`monitoring-grafana`, `vault`, `seaweedfs-s3`, `monitoring-kube-prometheus-prometheus`, `monitoring-loki-gateway`). `developmentApp.enabled` still selects `targetRevision: dev/main` and `values-dev.yaml` overlay, but no longer creates `-dev` service suffixes (ADR-012 follow-up 2026-09-02).
- Leave `coredns-patch` (wave `0`), `velero` (`Service/rustfs-egress` + `NetworkPolicy`), and all `NetworkPolicy` manifests unchanged — Flannel ignores them, Cilium will enforce later.
- Configure subpath-aware apps via their own charts (not via Ingress rewrite; Tailscale Ingress has no `rewrite-target`):
  - Grafana: `server.root_url = https://my-cluster.lonk-mirfak.ts.net/grafana/` + `serve_from_sub_path = true`
  - Prometheus: `--web.external-url=https://my-cluster.../prometheus` + `--web.route-prefix=/prometheus`
  - ArgoCD: `server.baseHRef: /argocd` (or `argocd-cmd-params: --basehref /argocd`)
  - Vault/Longhorn/SeaweedFS: served via `proxy_pass` with trailing-slash rewrite; verified functional behind prefix without app config (Longhorn requires `location /longhorn/ { proxy_pass http://.../; }` plus redirect for `/longhorn`).

## Alternatives Considered

| Option | Tradeoff | Verdict |
|---|---|---|
| 7 Ingress + `ProxyGroup type: ingress` shared StatefulSet | Consolidates proxy **pods**, not hostnames/devices — still 7 MagicDNS + 7 certs | Rejected — doesn't solve device sprawl |
| 7 Ingress with `tailscale.com/hostname: my-cluster` same host | Operator rejects duplicate hostname across Ingresses per cluster (`validateIngress` duplicate check) | Invalid |
| One Ingress with cross-namespace backends | Kubernetes API forbids `Service` in different namespace than `Ingress` | Invalid |
| Expose `ingress-nginx` via single Tailscale Ingress (B) | Same effect as chosen but adds external `ingress-nginx` chart; heavier than embedded NGINX gateway | Deferred — embedded gateway is lighter for homelab; can migrate to `ingress-nginx` later without changing tailnet hostname |
| L3 `Service loadBalancerClass: tailscale` | Loses L7 TLS automation (Let's Encrypt via `tailscale serve`), no path routing | Rejected |

## Consequences

### Positive
- 1 tailnet device + 1 cert instead of 7. `tailscale admin` stays clean; cert quota no longer multiplied.
- Single source of truth for platform exposure stays in `platform/tailscale` (same boundary as ADR-001), now as gateway `ConfigMap`.
- Flannel-compatible; no `NetworkPolicy` or CNI change required.
- Rollback is `git revert` to 7 Ingresses (no operator or DNS change).
- `platform/tailscale` remains ingress-only + gateway; operator concerns stay in `platform/tailscale-operator`.

### Negative
- Apps that don't natively support subpath require NGINX `sub_filter`/`rewrite` trickery (Longhorn, SeaweedFS admin). Tested via gateway rewrite rules.
- Additional hop (`tailscale proxy -> gateway -> Service`). Negligible latency homelab-local.
- Gateway is a single point of failure within the `tailscale` namespace (mitigated by `replicas: 1` homelab, can scale to 2).

## Wave Ordering After Change

| Wave | Apps | Policy |
|---|---|---|
| `-1` | `tailscale-operator` (`platform/tailscale-operator`) | `healthy` |
| `0` | `coredns-patch`, `longhorn`, `velero` (+ bucket-init hook) | `healthy` |
| `1` | `vault` | `healthy` |
| `2` | `seaweedfs` | `healthy` |
| `3` | `monitoring` | `sync-only` |
| `4` | `tailscale` (gateway `Deployment/Service/ConfigMap` + single `Ingress my-cluster`) | `sync-only` |

## Verification

- `helm template platform/tailscale | grep -c "kind: Ingress"` → `1` (was `7`)
- `helm template platform/tailscale | grep "my-cluster"` → present; no `argocd.lonk-mirfak`, `grafana.lonk-mirfak` hosts
- `helm template platform/tailscale | grep "cluster-gateway"` → `Deployment/Service/ConfigMap`
- `helm lint platform/tailscale` + `just validate` pass
- `kubectl get ingress -n tailscale my-cluster -o jsonpath='{.status.loadBalancer.ingress}'` → `my-cluster.lonk-mirfak.ts.net`
- From tailnet: `curl -k https://my-cluster.lonk-mirfak.ts.net/grafana/login` 200, `/argocd` 307, `/prometheus` 302, `/vault/ui` 200, `/longhorn` 200

## References

- ADR-001: `001-tailscale-ingress-placement.md` — original centralized placement (superseded in part)
- ADR-010: `010-tailscale-oauth-ci-generated.md` — wave topology and CI secret flow
- ADR-011: `011-tailscale-dns-np.md` — CoreDNS stub + NetworkPolicy scoping (unchanged)
- Tailscale KB 1236: https://tailscale.com/kb/1236/kubernetes-operator — `ingressClassName: tailscale`, `tailscale serve`, `TLS hosts` single label
- Tailscale operator `ingress-for-pg.go:validateIngress()` — duplicate hostname + `ValidLabel` checks
- Tailscale issue #10330, #20604 — single-host funnel workaround and shared-identity FR

---

## Amendment 2026-09-02: Vault Moved to Dedicated Device (Supersedes /vault Path)

**Status:** Accepted · **Amends:** Decision section `gateway /vault` location · **Reason:** Vault UI has no subpath support.

Vault's UI and API assume root (`/ui/`, `/v1/`). Serving it under a gateway prefix `/vault/` required fragile `sub_filter` HTML/JS rewriting, disabling backend gzip, and shimming absolute `/v1/`/`/ui/` fallbacks. This broke on Vault upgrades and left `JSON.parse` HTML errors on missed rewrites. Upstream confirms subpath is unsupported:

- hashicorp/vault#9221 — "Vault UI does not support running under a subpath / prefix" (closed, won't fix)
- hashicorp/vault/discussions/12719 — community workarounds for subpath / `X-Forwarded-Prefix` remain fragile; no official `root_url` / `base_href` equivalent

**Amended Decision:**

- Remove `vault` `location` blocks (`/vault/`, `/vault/v1/`, `/v1/`, `/ui/` shims) from `platform/tailscale/templates/gateway-configmap.yaml`. Gateway now routes 5 services: `argocd`, `grafana`, `prometheus`, `longhorn`, `seaweedfs-*` via `my-cluster.lonk-mirfak.ts.net`.
- Add `platform/tailscale/templates/vault-ingress.yaml` (`namespace: vault`, `ingressClassName: tailscale`, `service: vault:https`, `tls.hosts: vault-my-cluster` / `dev-vault-my-cluster` gated by `vault.enabled` + `developmentApp.enabled`). This restores the pre-ADR-012 dedicated `Ingress` pattern for Vault only, at `https://vault-my-cluster.lonk-mirfak.ts.net` (dev: `dev-vault-my-cluster`).
- `platform/tailscale/values.yaml` keeps `vault.enabled: true` but now documents it as the dedicated-device toggle, not a gateway prefix. `Chart.yaml` description updated to "Hybrid: 1 gateway device my-cluster for 5 services + dedicated vault-my-cluster device for Vault (2 devices total)".
- Tailnet footprint becomes **2 devices / 2 certs** (`my-cluster`, `vault-my-cluster`) instead of 1. This is an intentional trade-off: correctness and upgrade safety for Vault outweighs the single-device ideal. All other services retain the single-host gateway benefit.

**Consequences of Amendment:**

- Vault is no longer reachable at `https://my-cluster.../vault/` (gateway returns updated 404 listing 5 paths + vault hint). Direct hostname `vault-my-cluster.lonk-mirfak.ts.net` is the canonical Vault URL; update docs/runbooks.
- No `sub_filter` or `proxy_ssl_verify off` complexity in gateway for Vault; gateway `nginx.conf` is simpler and not coupled to Vault release.
- Rollback: re-add vault locations to gateway ConfigMap and delete `vault-ingress.yaml` (or keep both, but duplicate Vault exposure is not intended).

**Updated Verification (amended):**

- `helm template tailscale platform/tailscale --values platform/tailscale/values.yaml` renders **2** Ingresses (`my-cluster` in `tailscale` + `vault` in `vault`) and gateway `nginx.conf` contains no `/vault/` location.
- `helm template tailscale platform/tailscale --values platform/tailscale/values-dev.yaml` renders hosts `dev-my-cluster` + `dev-vault-my-cluster`.
- `helm lint platform/tailscale` + `just validate` pass.

---

## Superseded 2026-09-22 by ADR-018: Per-App Ingresses, Gateway Removed

**Status:** Superseded · **Reason:** per-app prefix fragility outweighed the device saving.

The Vault amendment above was the first concession; the same subpath problem applied to every remaining gateway app (Grafana `root_url`, ArgoCD `baseHRef`, Prometheus `route-prefix`, NGINX `sub_filter`/`rewrite` for Longhorn/SeaweedFS). Decision: one Tailscale `Ingress` + device per app at `/` root (`argocd`, `grafana`, `prometheus`, `longhorn`, `seaweedfs-s3`, `seaweedfs-admin`, `homepage`, `hubble`, `vault`; `-dev` suffix in dev), gateway `Deployment`/`Service`/`ConfigMap`/`PDB` deleted. See [ADR-018](018-per-app-tailscale-ingress.md) for the full decision, alternatives, and verification.
