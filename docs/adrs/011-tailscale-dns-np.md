# ADR-011: Tailscale DNS Scoping via CoreDNS Sibling + NetworkPolicy

> **Amendment (2026-10-13).** The `seaweedfs` device/list entries below are historical; the in-cluster chart was removed (see ADR-024) and RustFS is now the external S3 endpoint.

**Status:** Accepted · **Date:** 2026-09-01 · **Deciders:** Seom88

## Context

Velero needs to resolve `rustfs.lonk-mirfak.ts.net` (MagicDNS) over Tailscale, but CoreDNS
previously shipped a broken `platform/tailscale-operator/templates/coredns-configmap.yaml`
that replaced the entire Corefile, nested `ts.net:53` inside `.:53`, hardcoded
`10.104.254.48`, and crashed CoreDNS. The singleton `DNSConfig ts-dns` was empty
(`nameserver: {}`), so `status.nameserver.ip` never populated. Docs described a
`hostNetwork: true` + `ClusterFirstWithHostNet` fallback in the `velero-bucket-init` Job
that drifted from manifests and coupled backup to Talos host network.

CoreDNS is cluster-wide. Scoping must ensure only `velero` can reach the Tailscale
nameserver/proxy, without per-pod `dnsConfig` injection or cluster DNS outage.

## Decision

**CoreDNS remains cluster-wide; scoping via NetworkPolicy. Additive sibling patch only.**

- Delete the invalid `coredns-configmap.yaml`.
- Pin `DNSConfig` to `tailscale/k8s-nameserver:stable` (repo+tag as per CRD, digest
  `sha256:86b1eaa...` tracked in comment).
- Add `platform/coredns-patch` chart (Helm, Argo wave `0` `healthy`) with RBAC
  (`ServiceAccount coredns-patch`, `Role` patch `kube-system/coredns`, `ClusterRole`
  get `DNSConfig/status`). Job polls `DNSConfig.status.nameserver.ip` up to 120s,
  then idempotently ensures `ts.net:53 { forward . <ip> }` sibling **before** `.:53`
  in `kube-system/coredns` ConfigMap, relying on `reload` plugin hot-reload and
  `rollout restart` fallback. No hardcoded IP; rotation re-patched on next sync.
- Keep standalone `Service/rustfs-egress` `ExternalName` with `tailscale.com/tailnet-fqdn:
  rustfs.lonk-mirfak.ts.net` (ProxyGroup HA deferred — homelab overkill).
- Scope egress with standard `NetworkPolicy` (Cilium-compatible):
  `velero-allow-dns` → `kube-system/k8s-app=kube-dns:53`,
  `velero-allow-tailscale-egress` → `tailscale:53,443`,
  `velero-default-deny-egress` (`podSelector:{}` `policyTypes:Egress`) default deny.
- Remove `hostNetwork`/`ClusterFirstWithHostNet` from `velero-bucket-init`
  (`ClusterFirst`, 120s `nslookup` loop retained); CoreDNS stub is healthy before
  wave `0` hook, so host fallback is no longer needed.

## Alternatives Considered

| Option | Tradeoff | Verdict |
|---|---|---|
| `CiliumNetworkPolicy` `toFQDNs` | Cilium-only, ties egress to Cilium DNS-aware policy | Deferred — use standard `NetworkPolicy` first |
| Per-pod `dnsConfig` via Kyverno/Kustomize | Fragile NXDOMAIN, search-path breaks, drift per workload | Rejected |
| Helm `lookup` for Service ClusterIP | Argo `helm template` has no cluster → nil, breaks `just validate` | Rejected |
| Service DNS `ts-dns.tailscale.svc.cluster.local` as forward target | `forward` prefers IP, potential CoreDNS loop, no stable Service DNS guarantee | Rejected |

## Consequences

### Positive

- Repo-only fix; no host/Talos changes, no hardcoded IPs.
- `ts.net` stub is GitOps-managed and rotation-aware.
- Only `velero` namespace can egress to Tailscale DNS/proxy; other namespaces blocked by default deny.
- `hostNetwork` coupling removed; wave `-1` healthy → `0` patch → `0` velero ordering is declarative.

### Negative

- Operator `Degraded` still blocks waves `0..4` until `DNSConfig` status populates.
- Velero restore depends on CoreDNS patch health; if patch fails, `rustfs` stays unresolvable
  (mitigated by Job `backoffLimit:3` and `reload` idempotency).

## Wave Ordering After Change

| Wave | Apps | Policy |
|---|---|---|
| `-1` | `tailscale-operator` | `healthy` |
| `0` | `coredns-patch` (`platform/coredns-patch`), `longhorn`, `velero` (+ bucket-init hook) | `healthy` |
| `1` | `vault` | `healthy` |
| `2` | `seaweedfs` | `healthy` |
| `3` | `monitoring` | `sync-only` |
| `4` | `tailscale` (ingress-only) | `sync-only` |

## Verification

- `helm template platform/tailscale-operator | grep -q k8s-nameserver` and no `10.104.254.48`.
- `helm template platform/coredns-patch | grep -q "ts.net:53"` and no hardcoded `10.x`.
- `helm template platform/velero | grep -q velero-allow-dns` and no `hostNetwork: true`.
- `just validate` passes; `kubectl get cm coredns -n kube-system -o yaml` shows `ts.net:53` sibling before `.:53`.
- `kubectl exec -n velero deploy/velero -- nslookup rustfs.lonk-mirfak.ts.net` succeeds; non-velero egress to `tailscale:443` blocked.

## References

- ADR-010: `010-tailscale-oauth-ci-generated.md` — wave topology and CI secret flow updated to reference this patch.
- Tailscale Operator DNSConfig: https://tailscale.com/kb/1236/kubernetes-operator#dnsconfig
- CoreDNS stubDomains: https://kubernetes.io/docs/tasks/administer-cluster/dns-custom-nameservers/
