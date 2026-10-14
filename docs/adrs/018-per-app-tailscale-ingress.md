# ADR-018: Per-App Tailscale Ingresses (Revert ADR-012 Gateway)

> **Amendment (2026-10-11).** The ingress proxies were pooled behind a single 2-replica `ProxyGroup` (`ingress-proxies`) + `ProxyClass` (`prod-proxies`); every per-app Tailscale Ingress gained `tailscale.com/proxy-group: ingress-proxies` instead of provisioning its own proxy pod. MagicDNS per-app hostnames are preserved via each Ingress's TLS host. The `seaweedfs-s3`/`seaweedfs-admin` Ingresses referenced below are historical (chart removed 2026-10-13).

**Status:** Accepted · **Date:** 2026-09-22 · **Deciders:** Seom88 · **Supersedes:** [ADR-012](012-single-host-cluster-gateway.md) (gateway + vault amendment) · **Related:** [ADR-001](001-tailscale-ingress-placement.md), [ADR-014](014-cilium-cni-and-identity-networkpolicies.md)

## Context

ADR-012 consolidated platform exposure into one tailnet device (`my-cluster` + in-namespace NGINX `cluster-gateway` with subpath routing) to save MagicDNS devices and cert quota. A 2026-09-02 amendment already carved Vault out to a dedicated device (`vault-my-cluster`) because the Vault UI has no subpath support (`hashicorp/vault#9221`).

In practice the gateway accumulated the same class of problem for every remaining app: each service needed subpath awareness (`root_url` / `baseHRef` / `external-url` / `route-prefix`), NGINX `sub_filter`/`rewrite` shims for the ones without it (Longhorn, SeaweedFS), and every app upgrade risked breaking its prefix handling. The single-device saving no longer outweighed the per-app fragility — the exact trade-off the Vault amendment had already conceded for one service.

## Decision

**One Tailscale `Ingress` + device per app, every app served at `/` root. Remove the NGINX gateway.**

- Delete the gateway (`gateway-deployment.yaml`, `gateway-service.yaml`, `gateway-configmap.yaml`, `gateway-pdb.yaml`, `ingress.yaml`) from `platform/ts-ingress/templates/`.
- One `<app>-ingress.yaml` per service in `platform/ts-ingress/templates/` (`namespace: tailscale`, `ingressClassName: tailscale`, `rules.http.paths: [{path:/}]`), all following the `vault-ingress.yaml` pattern (the surviving pre-ADR-012 shape). Prod hosts use short pre-ADR-012 names; dev appends `-dev`:
  - `argocd`, `grafana`, `prometheus`, `longhorn`, `seaweedfs-s3`, `seaweedfs-admin`, `homepage`, `hubble`, `vault` (prod) → `<name>-dev` (dev).
- Revert subpath app config to root: Grafana `root_url=https://grafana.lonk-mirfak.ts.net/` + `serve_from_sub_path=false` (prod and dev equivalents); Prometheus drops `route-prefix` handling at the gateway level (per-env `external-url` stays).
- `platform/ts-ingress` `CiliumNetworkPolicies` shrink to DNS + default-egress only (no gateway pods left to protect); app-namespace `allow-ingress` rules no longer reference `tailscale/cluster-gateway`.
- `ts-ingress` stays wave `4` `sync-only`, always last — only the contents changed, not the ordering.

## Alternatives Considered

| Option | Tradeoff | Verdict |
|---|---|---|
| Keep gateway, fix shims per app | Preserves 2-device footprint; every upgrade re-risks prefix handling for 8 apps | Rejected — recurring toil, Vault precedent shows the pattern doesn't hold |
| Skip to Gateway API BYOD (roadmap v2, Envoy `gateway-envoy`) | Single device via standard `HTTPRoute`s; requires Envoy Gateway chart + `GatewayClass`/`Gateway`/`HTTPRoute` rollout | Deferred — correct long-term direction (roadmap v2), heavier change than needed now |
| L3 `Service loadBalancerClass: tailscale` per app | No subpath issues; loses L7 TLS automation per hostname | Rejected — same device count, worse TLS story |

## Consequences

### Positive
- Every app at `/` root: no `sub_filter`/`rewrite`, no per-app prefix config, upgrades can't break path handling.
- `platform/ts-ingress` is pure Ingress manifests — no NGINX image to pin, scan, or CVE-triage (drops out of the Trivy first-party list).
- Rollback is `git revert` to the gateway tree (no operator or DNS change).

### Negative
- Tailnet footprint grows to 9 app devices + `k8s-nameserver` + `rustfs-egress` (was 2 + 2). Accepted: correctness over device count; roadmap v2 (Envoy BYOD `gateway-envoy`) reconsolidates when taken up.
- One cert per device instead of shared; within Let's Encrypt quota at homelab scale.

## Verification

- `helm template platform/ts-ingress | grep -c "kind: Ingress"` → `9` (was `2`)
- `helm template platform/ts-ingress --values platform/ts-ingress/values-dev.yaml` → 9 `-dev` hosts, no duplicates
- `helm lint platform/ts-ingress` + `just validate` pass
- From tailnet: `https://grafana.lonk-mirfak.ts.net/login`, `https://argocd.lonk-mirfak.ts.net/`, `https://vault.lonk-mirfak.ts.net/` at root

## References

- ADR-012: `012-single-host-cluster-gateway.md` — gateway decision reverted here
- ADR-012 amendment 2026-09-02 — Vault dedicated device, the first crack in the gateway model
- hashicorp/vault#9221 — Vault UI has no subpath support
- Roadmap v2 (Gateway API BYOD): `../roadmap.md` — long-term reconsolidation via `gateway-envoy`

---

## Amendment 2026-09-22: Ingresses Move to Owning Charts, `ts-ingress` Chart Deleted

**Status:** Accepted · **Amends:** Decision section `platform/ts-ingress` layout + proxy-egress policy home · **Reason:** the chart was pure overhead once the gateway was gone.

With no gateway left, `platform/ts-ingress` held only 8 `Ingress` manifests plus Cilium policies for the `tailscale` namespace — while every rule in those policies exists to serve backends owned by other charts. Decision:

- Delete the `platform/ts-ingress` chart and the wave-`4` ArgoCD app (`04-ts-ingress.yaml`). There is no wave 4 anymore; `ts-operator` (wave `-1`) is the only Tailscale app.
- Each chart owns its `Ingress` via a `tailscaleIngress` values block (explicit `hostname`, `-dev` in dev): `homepage`, `monitoring` (`grafana` + `prometheus`), `longhorn`, `seaweedfs` (`s3` + `admin`), `vault`. Orphan apps owned by the infra repo (`argocd`, `hubble-ui`) ship from `platform/ts-operator/templates/infra/`.
- Proxy→backend Cilium egress moves to `platform/ts-operator` as `ts-operator-proxy-egress` (`selector: tailscale.com/managed=true`); the `ts-ingress` DNS/default-egress rules were already covered by the operator chart's own policies and are dropped, not duplicated.
- Prometheus `externalUrl`/`routePrefix` fixed to root (`https://prometheus[-dev].lonk-mirfak.ts.net/`, no `routePrefix`) — the last `my-cluster` subpath remnant.

**Updated Verification (amended):**

- `helm template` per chart renders its Ingresses: `homepage` 1/1, `monitoring` 2/2, `longhorn` 1/1, `seaweedfs` 2/2, `vault` 1/1, `ts-operator` 2/2 (prod/dev) with `-dev` hosts in dev
- `ts-operator` renders 4 `CiliumNetworkPolicy` docs including `ts-operator-proxy-egress`
- `helm lint` (all 6 charts, 0 failed) + `just validate` pass
