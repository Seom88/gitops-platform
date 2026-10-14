# ADR-014: Cilium CNI Migration and Identity-Aware NetworkPolicies

> **Amendment (2026-10-13).** The `platform/seaweedfs` chart was removed in commit 0759031; the `seaweedfs` namespace no longer exists and S3 storage is now the external RustFS endpoint. Namespaces without a policy owed to that chart (`longhorn-system`, `ts-operator-proxy`, `monitoring`, …) are unchanged. Section 2's transport rules for `seaweedfs` apply to the historical chart only.

**Status:** Accepted · **Date:** 2026-09-02 · **Deciders:** Seom88 · **Related:** [ADR-011](011-tailscale-dns-np.md), [ADR-012](012-single-host-cluster-gateway.md)

## Context

The platform previously operated with Flannel/default CNI and standard Kubernetes `NetworkPolicy` resources (`networking.k8s.io/v1`). Standard NetworkPolicies present severe limitations in a modern zero-trust GitOps homelab:
1. **IP-based vs Identity-based:** Standard Kubernetes NetworkPolicies map to IP tables or simple IP sets, lacking eBPF acceleration and native L7 / DNS-aware awareness.
2. **DNS & FQDN filtering:** Pods contacting external services (such as Tailscale control plane, RustFS over Tailscale MagicDNS, or AWS endpoints) required broad IP blocks or complete egress bypass because standard NetworkPolicy cannot inspect DNS queries (`toFQDNs`).
3. **Observability gaps:** Diagnosing dropped storage traffic or unauthorized cross-namespace requests required packet sniffing or reading raw controller logs, rather than flow-level observability with eBPF (Hubble).
4. **Service mesh and Gateway API:** Replacing kube-proxy with eBPF-based host-routing and native Kubernetes Gateway API requires Cilium as the foundational CNI substrate in Talos Linux.

The companion infrastructure repo (`infra-talos-homelab`) introduced Cilium v1.20.1 in `kubeProxyReplacement` mode with Gateway API CRDs v1.2.3. The GitOps repository needed to align by introducing native `CiliumNetworkPolicy` across all platform services (`vault`, `longhorn`, `seaweedfs`, `monitoring`, `tailscale`, `tailscale-operator`, `velero`, `coredns-patch`).

## Decision

**Migrate platform components to CiliumNetworkPolicies (`cilium.io/v2`) with portfolio-grade zero-trust policies, DNS egress filtering, and unblocked storage data planes.**

1. **Layered Policy Templates:**
   - Add `templates/cilium-networkpolicies.yaml` to each platform chart gated under `.Values.ciliumNetworkPolicy.enabled` (defaulting to `true`).
   - Implement three core policies per namespace:
     - `<app>-allow-dns`: Restricts DNS resolution to `kube-system/k8s-app=kube-dns` on port 53 (UDP/TCP) with Cilium L7 DNS rules (`matchPattern: "*"`).
     - `<app>-allow-egress`: Strict allowlist for `kube-apiserver`, external targets, and Hubble relay (`port 4244/4245`).
     - `<app>-allow-ingress`: Restricts inbound access to approved callers (e.g. Tailscale cluster-gateway, monitoring Prometheus scrapes, and health check probes).

2. **Storage and Dynamic Workload Invariant (Longhorn & SeaweedFS):**
   - For distributed storage (`longhorn-system` and `seaweedfs`), intra-namespace egress and ingress must remain unrestricted across components:
     - Longhorn data plane dynamically allocates ephemeral replica and engine ports (TCP 10000–30000) and instance-manager services (TCP 8500–8504). Strict per-port filtering inside `longhorn-system` causes attachment deadlocks (`DeadlineExceeded`).
     - SeaweedFS inter-pod volume/master/filer synchronization uses broad RPC ranges.
   - Intra-namespace traffic is therefore scoped to namespace identity (`k8s:io.kubernetes.pod.namespace: <namespace>`) without restricting storage ports.

3. **Prometheus ServiceMonitor Decoupling:**
   - Remove `global.seaweedfs.monitoring.enabled: true` from SeaweedFS to eliminate the circular startup dependency where SeaweedFS failed to sync before Prometheus Operator CRDs were installed.
   - Move SeaweedFS `ServiceMonitor` definitions into `platform/monitoring/templates/seaweedfs-servicemonitors.yaml`, where Prometheus Operator CRDs are guaranteed to exist.

4. **Tailscale & Gateway API Alignment:**
   - Allow MagicDNS and Tailscale proxy traffic on port 1053 and 443 in `tailscale-operator` and `tailscale` policies.
   - Enable single-host gateway ingress to forward traffic seamlessly to backend services (`/vault`, `/grafana`, `/prometheus`, `/longhorn`, `/seaweedfs-*`).

## Alternatives Considered

| Option | Tradeoff | Verdict |
|---|---|---|
| Upstream Helm chart NetworkPolicies (`flavor: cilium` where available) | Only `kube-prometheus-stack` supports Cilium flavor upstream; others (`vault`, `longhorn`, `seaweedfs`) either only support standard K8s NetworkPolicy or none at all. Does not cover cross-app flows (e.g. Loki to SeaweedFS S3 or Tailscale gateway ingress). | Rejected — fragmented management |
| Standard Kubernetes `NetworkPolicy` (`networking.k8s.io/v1`) | No FQDN egress rules, no L7 DNS visibility, no eBPF identity filtering, difficult to debug silent drops. | Rejected — lacks zero-trust fidelity |
| Global Default-Deny Clusterwide (`CiliumClusterwideNetworkPolicy`) | Extreme blast radius; breaks bootstrapping of core components and kubelet probes unless all exceptions are pre-discovered. | Rejected — namespace-scoped policies provide safer incremental adoption |

## Consequences

### Positive
- **True Zero-Trust:** Network traffic is locked down by cryptographic Cilium endpoint identity rather than volatile pod IPs.
- **FQDN & DNS Auditing:** Outbound calls to external SaaS and MagicDNS domains are audited and restricted at Layer 7.
- **Decoupled Monitoring:** Storage and GitOps applications deploy cleanly on fresh clusters without CRD deadlocks.
- **eBPF Performance:** Native kernel-level packet routing without kube-proxy iptables overhead.

### Negative / Operational Notes
- Any new inter-service communication (e.g., a new backup target or scraping endpoint) must be explicitly registered in the calling chart's `cilium-networkpolicies.yaml`.
- Health check probes (`host` and `remote-node` entities) must be explicitly allowed on pods with custom probe ports.

---

## Amendment 2026-09-22: Gateway Ingress Consequence Removed ([ADR-018](018-per-app-tailscale-ingress.md))

The `cluster-gateway` ingress allowances above (§Tailscale & Gateway API Alignment, `allow-ingress` callers) no longer apply: the NGINX gateway is deleted and `platform/ts-ingress` policies are DNS + default-egress only. The decision (central per-namespace Cilium policies) is unchanged; only the gateway consequence is void.

> **Follow-up 2026-09-22 ([ADR-018 amendment](018-per-app-tailscale-ingress.md)):** the `platform/ts-ingress` chart itself is deleted. The proxy→backend egress rules now live in `platform/ts-operator` as `ts-operator-proxy-egress`; each chart owns its `Ingress` via `tailscaleIngress` values.
