# Networking — Cilium eBPF, Gateway API & Policies

> **Single source of truth for Cilium networking.** Cilium 1.20.1 (eBPF, strict kubeProxyReplacement) + Gateway API 1.2.3 + Hubble; 9 charts with gated `CiliumNetworkPolicy` (ADR-014). Legacy `networking.k8s.io/v1` `networkpolicy.yaml` is retained for non-Cilium fallback (Flannel) but not enforced.

## Quick path

1. **Verify CNI is Ready** — Cilium and the Gateway API CRDs are cluster prerequisites, so they must already be installed before this repo's policies are enforced:
   ```bash
   kubectl -n kube-system get pods -l k8s-app=cilium
   cilium status
   kubectl get ciliumnetworkpolicies -A
   ```
2. **Deploy this repo** via `bootstrap/init-gitops.sh prod` — ArgoCD waves apply Cilium policies per namespace.
3. **Observe flows:** `hubble observe -n <ns> --follow` or `hubble observe --verdict DROPPED` for silent drops.

## Versions

| Component | Version | Where |
|-----------|---------|-------|
| Cilium CNI | `1.20.1` | Cluster prerequisite — installed before this repo syncs |
| Gateway API CRDs | `1.2.3` | Cluster prerequisite — installed before Cilium |
| Hubble relay | `4244` (gRPC) / `4245` (UI/health) | Cilium + per-chart Tailscale Ingress |
| Policy API | `cilium.io/v2` (`CiliumNetworkPolicy`) | `platform/*/templates/cilium-networkpolicies.yaml` (9 charts) |

## Cluster prerequisites

This repository does not install the CNI. The policy model below assumes a Cilium install with the following settings, which the `CiliumNetworkPolicy` rules and the `allow-dns` / `allow-egress` allows are written against:

```yaml
ipam: kubernetes
kubeProxyReplacement: strict
socketLB:
  hostNamespaceOnly: true
gatewayAPI:
  enabled: true
```

Gateway API CRDs must be present before Cilium starts, otherwise the Gateway resources rendered by platform charts fail to apply.

## Policy model

### Cilium vs Kubernetes NetworkPolicy

| | `networking.k8s.io/v1` | `cilium.io/v2` (`CiliumNetworkPolicy`) |
|---|---|---|
| Identity | Pod IP / CIDR | Cryptographic endpoint identity (stable across rescheduling) |
| L7 / DNS | No | `toFQDNs` + `rules.dns` (FQDN-aware egress, `matchPattern: "*"`) |
| Entities | Limited | `toEntities: {host, remote-node, kube-apiserver, health}` |
| Observability | None | Hubble flow logs (verdict, policy, DNS) |
| Enforcement here | Not enforced with Cilium (retained for non-Cilium clusters) | **Enforced** — gated by `ciliumNetworkPolicy.enabled` |

### 3-rule template per namespace

Each chart renders `platform/<app>/templates/cilium-networkpolicies.yaml` gated by `.Values.ciliumNetworkPolicy.enabled` (default `true`). Default posture is **deny** — `endpointSelector: {}` selects all pods in the namespace; no `from`/`to` means deny.

| Policy | Direction | Key rules |
|--------|-----------|-----------|
| `<app>-allow-dns` | Egress | `toEndpoints: {k8s-app: kube-dns, k8s:io.kubernetes.pod.namespace: kube-system}` on UDP/TCP 53 + `toFQDNs: [{matchPattern: "*"}]` + `rules.dns` |
| `<app>-allow-egress` | Egress | `kube-apiserver` (443/6443), `hubble-relay` (4244), intra-namespace (`k8s:io.kubernetes.pod.namespace: <ns>`), plus per-app specifics (Vault Raft, Longhorn, SeaweedFS) |
| `<app>-allow-ingress` | Ingress | Intra-namespace, `toEntities: {host, remote-node, kube-apiserver}` + `health` probes |

Policy specifics (ADR-014): Vault ingress is allowed from the `vault` namespace (`fromEndpoints` same-ns), policies match both `app.kubernetes.io/name` and `app` labels, storage namespaces are unrestricted intra-namespace (see below), and Hubble `4244/4245` is whitelisted.

### Toggling policies

```yaml
# platform/<app>/values.yaml
ciliumNetworkPolicy:
  enabled: true  # set to false for non-Cilium clusters
```

When `false`, the `CiliumNetworkPolicy` resources are not rendered; legacy `networkpolicy.yaml` remains but is not enforced without Cilium. Use `false` only for local non-Cilium dev clusters.

## Tailscale integration

- **Control plane / DERP / STUN:** Tailscale clients and `tailscale-operator` need egress to DERP and STUN. Policies allow UDP `1-65535` + TCP `80/443` for Tailscale control plane where required; MagicDNS (`*.ts.net`) is covered by the `allow-dns` FQDN rule (not a broad egress hole).
- **Per-app Tailscale ingress:** each chart renders its own `Ingress` via `tailscaleIngress` values (`ingressClassName: tailscale`), each creating its own MagicDNS device (`argocd`, `grafana`, `prometheus`, `longhorn`, `seaweedfs-s3`, `seaweedfs-admin`, `homepage`, `hubble`, `vault` on `*.lonk-mirfak.ts.net`; `-dev` hostnames in dev). Orphan apps (`argocd`, `hubble-ui`) ship from `platform/ts-operator/templates/infra/`. Every app is served at `/` root — no subpath routing — see [ADR-018](adrs/018-per-app-tailscale-ingress.md). Proxy→backend Cilium egress lives in `ts-operator` as `ts-operator-proxy-egress`.

## Hubble

| What | Port | Notes |
|------|------|-------|
| Relay gRPC | `4244` | Whitelisted in every `allow-egress` |
| Relay health / UI | `4245` | Probe + UI path |
| UI via per-app Ingress | `443` (Tailscale serve) | `https://hubble.lonk-mirfak.ts.net/` |

```bash
# Live flows (allow-listed vs dropped)
hubble observe -n vault --follow
hubble observe --verdict DROPPED
hubble observe --pod vault/vault-0 --follow

# Quick health
hubble status
cilium connectivity test  # full mesh test (run after CNI changes)
```

All dashboards remain behind Tailscale; each app has its own per-app Ingress device.

## Storage exceptions (ADR-014 invariant)

Distributed storage data planes use dynamic/ephemeral ports; strict per-port intra-namespace filtering causes deadlocks (`DeadlineExceeded`).

| Namespace | Ports / ranges | Policy |
|-----------|----------------|--------|
| `longhorn-system` | `9500`, `8000`, `8500-8503` + ephemeral `10000-30000` (replica/engine/instance-manager) | Intra-namespace **unrestricted** (`k8s:io.kubernetes.pod.namespace: longhorn-system` without port restriction) |
| `seaweedfs` | `8333` (S3), `9333` (Filer), inter-volume/master RPC ranges | Intra-namespace **unrestricted** |

Cross-namespace to storage is still deny-by-default; only intra-namespace is open.

## Verification

```bash
# Policies present (9 charts × 3)
kubectl get ciliumnetworkpolicies -A
kubectl get ciliumnetworkpolicies -n vault -o yaml | grep -E "endpointSelector|toFQDNs|toEntities"

# Cilium health + connectivity
cilium status
cilium connectivity test --test-namespace cilium-test

# Helm render check (no cluster needed)
# Two-argument form: helm template <release-name> <chart-path>.
# The single-argument form is not portable — Helm 3 reads a lone positional
# argument as the release name and then has no chart to render.
helm template vault platform/vault --set ciliumNetworkPolicy.enabled=true | grep -A2 "kind: CiliumNetworkPolicy"
helm template vault platform/vault --set ciliumNetworkPolicy.enabled=false | grep -c "CiliumNetworkPolicy"  # → 0

# Tailscale per-app Ingresses
kubectl -n tailscale get ingress -o wide  # argocd, grafana, prometheus, longhorn, seaweedfs-*, homepage, hubble, vault
curl -k https://grafana.lonk-mirfak.ts.net/login  # 200 via tailnet
```

## Troubleshooting — silent drops

Cilium denies are **silent** (no RST, just `DROP` verdict). Use Hubble before packet captures:

1. `hubble observe --verdict DROPPED --since 2m` — shows dropped flow, source/dest identity, port, DNS name, and denying policy.
2. Check the caller's `allow-egress` / callee's `allow-ingress` for missing `toFQDNs`, `toEntities`, or service ports.
3. Common fixes: add `toFQDNs.matchPattern` for new external FQDN, add `toEntities: {kube-apiserver}` for API access, allow `4244/4245` for Hubble, add a `tailscale-ingress.yaml` in the owning chart (or `ts-operator/templates/infra/` for control-plane apps) for a new UI route.
4. Temporarily set `ciliumNetworkPolicy.enabled=false` for the chart to confirm policy vs app bug, then re-enable with fix.

## Renovate & upgrades

`renovate.json` groups non-critical charts and auto-merges patch/minor updates; **Cilium, Gateway API, Vault, Longhorn, cert-manager** are labeled for manual review. Cilium major bumps (e.g., `1.20 → 1.21`) require a `cilium connectivity test` before merging GitOps changes.

## References

- ADR-014: [Cilium CNI and Identity-Aware NetworkPolicies](adrs/014-cilium-cni-and-identity-networkpolicies.md)
- ADR-018: [Per-App Tailscale Ingresses](adrs/018-per-app-tailscale-ingress.md) (supersedes ADR-012)
- Features deep dive: [eBPF Networking & Security](features-deep-dive.md#-ebpf-networking--security-with-cilium)
