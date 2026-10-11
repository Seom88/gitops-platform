# Roadmap

**Status:** v1.0.0 **not tagged** — blocked on the Velero restore drill · Cilium 1.20.1 (ADR-014) · Last updated: 28 Sep 2026

This document tracks what is currently deployed in the cluster, what is required to complete the **v1.0.0** release, and what is planned for **v2.0**. The cluster uses Cilium 1.20.1 + Gateway API 1.2.3 + CiliumNetworkPolicy (ADR-014); subsequent releases are expected to be additive. The [README](../README.md) contains a short summary and links here.

**This file is the single source of truth for the release state.** No other document in this repo carries its own version string or its own release date — they link here. There is no `VERSION` file, no `v1.0.0` git tag, and no `## [1.0.0]` CHANGELOG section; all three are created at declaration time, after the restore drill passes.

---

## What blocks v1.0.0

One item. Everything else in the v1 scope is deployed.

| # | Blocker | What is true today | What closes it |
|---|---------|--------------------|----------------|
| 1 | **Velero restore drill has never been run** | Backup is running (Velero deployed, `daily-full` to S3-compatible RustFS, bucket `velero-homelab`). Restore is **undrilled** — no recovery from a Velero backup has ever been executed. | Restore into a clean cluster with evidence captured per [`docs/restore-verification.md`](./restore-verification.md), and [`docs/cluster-recovery.md` §2](./cluster-recovery.md#2-restore-runbook) updated with what the drill actually showed. |

**Namespace ownership is a boundary, not a gap.** This repository deploys workloads into exactly ten namespaces and renders a gated `CiliumNetworkPolicy` for each. It deploys nothing at runtime into `argocd` — the ArgoCD `Application` objects under `gitops/` are consumed by the pre-installed cluster prerequisite, and the only other thing this repo places there is the `ts-operator`-owned `argocd` Ingress, which lives in `namespace: tailscale` and selects *toward* `argocd`, not inside it. `external-secrets` is the upstream chart `charts.external-secrets.io` and is **disabled** (`eso.enabled: false`). Neither has a first-party chart here, so there is no template to add; their policy belongs to the provisioning layer and to the upstream chart respectively. Full reasoning in [Policy coverage](#policy-coverage-adr-014). This is a disclosure for the release notes, not a deliverable of this release.

Nothing else gates v1.0.0. The **substrate** (Talos today; single-node bare-metal cutover planned per [ADR-019](./adrs/019-single-node-bare-metal-migration.md)) is an operational concern of the maintainer's, **not** a v1 gate — it is tracked in [`odd/tasks/ci-kubeconfig-k3s.md`](../odd/tasks/ci-kubeconfig-k3s.md) and outside this release's scope.

---

## Policy coverage (ADR-014)

Stated precisely, because the previous "10 charts — Complete" claim was wrong on both the count and the denominator.

| | Count | Detail |
|---|---|---|
| First-party charts in this repo | 11 | `gitops` + 10 under `platform/` and `apps/` |
| …that render `cilium-networkpolicies.yaml` | **10** | `platform/{vault,velero,longhorn,seaweedfs,monitoring,trivy-operator,ts-operator,valkey}`, `apps/{homepage,immich}` |
| …that do not | **1** | `gitops` (the App-of-Apps chart) — see note below |

The `argocd` and `external-secrets` workloads are **not first-party charts in this repo**; there is no `platform/argocd/` or `platform/external-secrets/` directory to add a template to. They are:

- **`argocd`** — a cluster **prerequisite**, pre-installed before this repo syncs. Policy for it belongs in the provisioning layer.
- **`external-secrets`** — the upstream chart `charts.external-secrets.io` version `2.11.0`, applied as an ArgoCD `Application` from [`gitops/templates/platform/00-external-secrets.yaml`](../gitops/templates/platform/00-external-secrets.yaml). Policy for it belongs in that manifest or a new first-party chart, not in a vendored template.

Both are currently disabled by default (`vault.enabled: false`, `eso.enabled: false` — see [`gitops/values.yaml`](../gitops/values.yaml)), which reduces today's exposure but does not close the gap: re-enabling them per [ADR-017](./adrs/017-vault-paused-sops-default.md) restores it. [`docs/networking.md`](./networking.md) is the detailed reference for the policy model.

---

## Where the project stands today

The cluster runs on end-to-end GitOps: ArgoCD as the App-of-Apps, SOPS + age as the default secrets path (Vault paused, not deleted — ADR-017), Tailscale per-app ingress (one device per app), and distributed storage via Longhorn + SeaweedFS. On top of that there's a CI layer that validates every push (`ci.yaml`: lint + Trivy in one run), and a controlled workflow for deploys (`deploy.yaml`).

**Topology.** The cluster was reduced from 3 workers to 1 node ([ADR-019](./adrs/019-single-node-bare-metal-migration.md)). This repo therefore delivers **pod-level** HA — PDBs, multi-replica stateless workloads, Longhorn snapshots, and off-cluster S3 backups — but **not node-level HA**. Node failure is total downtime: there is no pod redistribution and no Raft quorum. Multi-node HA is a property of the cluster, not of this repository. The migration target is single-node bare metal; the substrate choice is a maintainer concern and is not a v1.0.0 gate.

**What's already running in CI/CD**, verified directly against `.github/workflows/`:
- `ci.yaml` validate job: Helm dependency builds, `helm lint` and `helm template` (both prod and dev values), inline-image convention (`validate-images`), secret scan (`detect-secrets` baseline-gated), ShellCheck on the bootstrap scripts, YAML/JSON sanity checks, and `yamllint` as a non-blocking extra check.
- `ci.yaml` security jobs: Trivy image scans over the dynamically discovered chart images (matrix from rendered manifests) + repo misconfig scan (`scan-config`), SARIF upload to code scanning, weekly cron — fail-closed for digest-pinned first-party images (upstream subchart images advisory).
- `deploy.yaml`: auto-deploy on `CI` success (main) plus manual `workflow_dispatch` with environment selection (prod/dev), a Tailscale connection step, kubeconfig restore from Environment Secret `KUBECONFIG_DATA`, and a `force_reapply` flag for safe retries.
- Pre-commit (local mirror of the fast gates): `detect-secrets`, `check-yaml`/`check-json`, `yamllint`, `shellcheck`; `just validate` + `just scan` as local mirrors. <!-- pragma: allowlist secret -->
- `renovate.json`: weekly updates (Mondays before 5am), with differentiated rules — critical cluster components (Vault, Longhorn, cert-manager) require explicit manual review via labels, while non-critical charts and GitHub Actions are grouped and auto-merged; regex managers also cover hardcoded images and `HELM_VERSION`.

That's already a real, guided CI/CD foundation with fail-closed image scanning (pinned images) and secrets detection live — not a full DevSecOps pipeline yet (still missing egress policies for the `argocd` and `external-secrets` workloads, centralized audit logging, and the PSA `restricted` rollout), but not "nothing" either.

---

## Path to v1.0 — Phases 1 through 4

The scope for v1.0 is defined as Phases 1 through 4. Items previously labeled "Phase 5" or "Phase 1.2" are tracked under v2.0 below.

### Phase 1 — Foundation ✅ Complete

- [x] Bootstrap script: empty cluster → ArgoCD → Vault → apps
- [x] Vault (Raft, TLS, auto-unseal) — **built, then frozen and paused**; it is not a v1.0.0 deliverable. See [Vault return (ADR-017)](#vault-return-adr-017) under v2.0.
- [x] External Secrets Operator with per-service ClusterSecretStores — installed, but **disabled by default** alongside Vault (`eso.enabled: false`, ADR-017). The default secrets path is SOPS + age.
- [x] cert-manager for automated TLS
- [x] Tailscale operator with secure ingress (no public ports)
- [x] ArgoCD with custom health checks
- [x] Longhorn as distributed storage (wave 0)
- [x] Prometheus + Grafana + Loki
- [x] SeaweedFS as S3-compatible storage
- [x] Architecture Decision Records (ADRs)

### Phase 2 — Automation & Observability ✅ Complete

- [x] Monitoring stack deployed (Prometheus + Grafana + Loki + Alloy — Alloy `chart 1.12.1` DaemonSet via `discovery.kubernetes` → `loki.source.kubernetes` → `loki.write` to Loki gateway; stateless, RBAC auto-created; replaces Promtail — deprecated)
- [x] Dashboards reachable via Tailscale ingress (Grafana at `/grafana`, Prometheus at `/prometheus`; Loki datasource with `X-Scope-OrgID: fake`, Explore + LogQL)
- [x] CI pipeline — `ci.yaml` (validate job: lint, render, image-convention, secret scan, ShellCheck, sanity checks + security jobs: Trivy images + misconfig, SARIF, weekly cron) + `deploy.yaml` (auto on CI success + guided manual deploy)
- [x] Renovate — weekly updates with mandatory manual review for critical components (Vault, Longhorn, cert-manager) and grouped automerge for the rest

### Phase 3 — Storage & Scale ✅ Complete

- [x] Longhorn — distributed block storage
- [x] SeaweedFS — S3-compatible object storage
- [x] Loki → SeaweedFS integration for centralized logging (SingleBinary + gateway, buckets `loki-chunks`/`loki-ruler`)
- [x] Velero — **automated backup** (wave 0, S3-compatible RustFS backend, bucket `velero-homelab`, FQDN injected from `gitops/values.yaml`; `daily-full` 02:00, all namespaces, 30d TTL, Longhorn volumes via FsBackup; subchart `12.2.0` / app `1.18.2`) — deployed and running. Vault is excluded by policy; its hourly protection is the Longhorn `vault-hourly-snapshot` RecurringJob, not a Velero schedule. **Restore is not verified**: no drill has been run. See [What blocks v1.0.0](#what-blocks-v100).

### Phase 4 — Hardening & Developer Experience (in progress, v1.0)

Remaining scope for v1.0.0. The Cilium CNI (breaking change at the infrastructure layer) is already deployed.

**CNI (v1.0.0):**
- [x] Cilium CNI (eBPF, Gateway API, CiliumNetworkPolicy) — Cilium 1.20.1 + Gateway API 1.2.3 (ADR-014) — NetworkPolicy enforcement, Hubble observability, eBPF kubeProxyReplacement. Every namespace this repo deploys a workload into has a gated policy; namespaces owned by the provisioning layer do not: see [Policy coverage](#policy-coverage-adr-014).

**Security hardening (requires Cilium, planned for v1.0.0):**
- [x] Container image vulnerability scanning (Trivy) integrated into CI — fail-closed `Security` workflow (digest-pinned first-party images block on HIGH/CRITICAL outside `.trivyignore`; upstream subchart images advisory; deploy gated on Security + Validate)
- [x] Git secrets detection (`detect-secrets`) — pre-commit hook + `.secrets.baseline` (audited) + CI step, fails on new secrets

**Developer experience (v1.0):**
- [x] Bootstrap guard with `--force` flag for safe reapply
- [x] Status verifier (rerun bootstrap to check cluster health)
- [x] `just validate` + `just scan` as local mirrors of CI validation (incl. Trivy summary table)
- [x] Pre-commit fast gates (secrets, yaml/json, yamllint, shellcheck)
- [x] Real application examples deployed (Homepage digest-pinned dashboard, wave 3 `apps/homepage` + Immich on CloudNativePG, wave 5 `apps/immich` over wave-4 operator)

---

## v2.0 — Enterprise automation (beyond v1.0)

Items planned after v1.0.0. Expected to be additive; no CNI or storage re-architecture is planned.

### Vault return (ADR-017)

Vault is **paused, not deleted** ([ADR-017](./adrs/017-vault-paused-sops-default.md)). `platform/vault/` is frozen in `main` and both ArgoCD Applications are gated off (`vault.enabled: false`, `eso.enabled: false` in `gitops/values.yaml` and `gitops/values-dev.yaml`). SOPS + age is the default secrets path until velocity allows a return.

Vault is not a v1.0.0 deliverable. It returns when dynamic secrets, auto-rotation, or audit become requirements — then it is a flag flip plus a restore from the frozen archive (`unseal.json` + last `raft-*.snap` + `vault-tls` export), with the ESO stores re-enabled per ADR-002. Vault server replica count is currently **1** (ADR-019), so a return restores a single-replica server, not a 3-node Raft quorum.

### Decoupling & vendor-agnostic ingress (Gateway API BYOD)

Reduce Tailscale as a single point of trust and cut tailnet sprawl while keeping the current MagicDNS workflow intact. App routing moves to standard Kubernetes Gateway API (`GatewayClass` / `Gateway` / `HTTPRoute`) so swapping the underlying mesh (Tailscale → Netbird or other) later requires no app changes.

**Device inventory — 9 app devices → 1 (plus 1 infra device unchanged):**

| Tailnet device | Purpose | Today (per-app Ingresses — ADR-018) | After BYOD (v2 — 2 devices) |
|---|---|---|---|
| `k8s-nameserver` | Former `DNSConfig` device for MagicDNS `ts.net` → CoreDNS sibling `ts.net:53` (removed with `platform/coredns-patch`, ADR-011 historical) | ❌ removed | — |
| `rustfs-egress` | `ExternalName` `rustfs.lonk-mirfak.ts.net` for Velero/S3 via Tailscale | ✅ present | ✅ stays (future optional: consolidate via `TCPRoute`; out of scope for v2) |
| per-app Ingresses | One `Ingress` + device per app, owned by each chart via `tailscaleIngress` values (`argocd`/`grafana`/`prometheus`/`longhorn`/`seaweedfs-s3`/`seaweedfs-admin`/`homepage`/`hubble`/`vault`, each at `/` root; orphans in `ts-operator/templates/infra/`, ADR-018) | ✅ present (9 devices) | 🔀 consolidated — merged into `gateway-envoy` |
| `gateway-envoy` | Envoy Gateway `LoadBalancer` with `loadBalancerClass: tailscale` (BYOD) | — | ✅ **single device** serving all 9 app hostnames |

> Operator itself is control-plane only and not counted. `k8s-nameserver`/`DNSConfig` removed with `coredns-patch`; `rustfs-egress` is unchanged in v2.

**BYOD architecture (brief):**

- Envoy Gateway chart provides `GatewayClass: tailscale` and a `LoadBalancer` (`loadBalancerClass: tailscale`) — single Tailscale device `gateway-envoy` replaces the nine per-app L7 devices above. See [Tailscale BYOD Gateway API](https://tailscale.com/docs/solutions/kubernetes-operator-byod-gateway-api).
- One `Gateway` with multiple `listeners` / `hostnames` (one per app: `argocd`, `grafana`, `prometheus`, `longhorn`, `seaweedfs-s3`, `seaweedfs-admin`, `homepage`, `hubble`, `vault` on `*.lonk-mirfak.ts.net`), each terminating its own TLS cert. One `HTTPRoute` per service (replaces the per-app `Ingress`es).
- The NGINX gateway is already gone (ADR-018 removed `Deployment`/`Service`/`ConfigMap` + `sub_filter`/`rewrite` hacks); v2 only swaps the L7 frontend from per-app `Ingress`es to `HTTPRoute`s on `gateway-envoy`. Vault stays a standard hostname-routed route throughout.
- Substrate ready: Cilium Gateway API CRDs `v1.2.3` are already installed in the cluster (ADR-014); no CNI/storage change needed.

**Scope:**

| | In scope for v2 (immediate) | Future / optional (not v2) |
|---|---|---|
| Ingress | Consolidate the 9 per-app `Ingress`es onto one `gateway-envoy` device; keep MagicDNS (`*.lonk-mirfak.ts.net`) | Own domain via Pi-hole/CoreDNS authoritative + `ExternalDNS` + `cert-manager` + Tailscale split DNS (BYOD guide Steps 1–6); reduces MagicDNS dependency but not required for vendor-agnostic routing |
| Mesh | App `HTTPRoutes` stay vendor-agnostic; swapping `GatewayClass` from `tailscale` to `netbird`/other requires no app changes | Evaluation of alternative meshes (e.g. Netbird) as drop-in `GatewayClass` replacement |
| DNS / S3 | `rustfs-egress` untouched (`k8s-nameserver`/`DNSConfig` removed) | Own DNS/domain, `TCPRoute` for RustFS |

**Checklist — v2:**

- [ ] Install Envoy Gateway chart (Gateway API provider) and define `GatewayClass: tailscale`
- [ ] Define single `Gateway: gateway-envoy` (`LoadBalancer`, `loadBalancerClass: tailscale`) with per-app TLS listeners/hostnames and per-service `HTTPRoute`s (argocd, grafana, prometheus, longhorn, seaweedfs-s3, seaweedfs-admin, homepage, hubble, vault)
- [x] Remove L7 gateway hacks — done early via ADR-018 (NGINX `Deployment`/`Service`/`ConfigMap` deleted; per-app `Ingress`es at `/` root, no `sub_filter`/`rewrite`)
- [ ] Update docs/runbooks (URLs, `helm template` verification, `kubectl get gateway/httproute` checks, rollback to per-app `Ingress`es)

**Non-goals for v2:**

- Not removing Tailscale entirely — `rustfs-egress` and tailnet ACLs remain (`k8s-nameserver`/`DNSConfig` removed).
- Not touching the `rustfs-egress` device.
- No change to storage (Longhorn/SeaweedFS), Vault HA, or ArgoCD waves beyond ingress.

### Compliance & policy

- Pod Security Admission `restricted` rollout — 6 infra namespaces stay `privileged` by exception (Longhorn, monitoring, etc.); homepage is restricted-ready pilot — moved from v1, requires full project to validate
- NetworkPolicy gap-closing & hardening — per-namespace allows exist for every namespace this repo deploys a workload into ([Policy coverage](#policy-coverage-adr-014)); the remaining hardening work — Vault Raft 8201 audit, tightening broad allows — stays here. Must re-validate with every new app.
- Security architecture documentation (minimal threat model, attack surface, incident response) — moved from v1
- Kyverno — admission-time policy enforcement (policy-as-code)
- CIS Benchmark — automated Kubernetes security validation
- RBAC audit — access pattern reports
- Compliance dashboard (SOC 2 / PCI-DSS) in Grafana

### Observability & audit

- Centralized audit logging (Kubernetes API + Vault → Loki) — moved from v1, requires cluster-provisioning changes + control-plane restart

### Supply chain & image security

- Supply chain hardening — chart signing, SBOM, dependency scanning
- Trivy Operator via ArgoCD (`trivy-system`, automated sync, `ignoreUnfixed: true`) — ✅ chart + Application added (`platform/trivy-operator`, wave 3); continuous in-cluster scanning every 6h, results as CRDs integrated with Prometheus; complements CI-time `Security` workflow

### Automation

- Automated secrets rotation (Tailscale, S3, API keys) via CronJob

### Python automation & image security

- Ops CLI (`gitops-ops`) built with Typer + a Kubernetes client + HVAC, for bootstrap, health checks, image scanning, secrets rotation, and cluster diagnostics
- Infrastructure tests with pytest + testinfra (Vault unsealed, ArgoCD healthy, secrets synced, no root pods)
- Observability exporter with custom Prometheus metrics (Vault seal state, ArgoCD drift, Longhorn rebuilds)
- Automated compliance scanning (CIS, PCI-DSS checklist, policy violation alerts)

### Documentation & onboarding

- Customization guide refreshed (current `platform/*.yaml` layout + real wave table) and tested end-to-end — moved from v1, waits until the app set stabilizes (v2 changes ingress)

---

## v1.0 release checklist

**Already complete:**
- [x] ArgoCD App-of-Apps
- [x] Zero-trust ingress via Tailscale
- [x] Longhorn + SeaweedFS
- [x] Prometheus + Grafana + Loki + Alloy (DaemonSet log collector)
- [x] Velero — **automated backup** (Wave 0, RustFS S3 `velero-homelab`, chart `12.2.0` / app `1.18.2`)
- [x] Cilium CNI (eBPF, Gateway API, CiliumNetworkPolicy) — Cilium 1.20.1 + Gateway API 1.2.3 (ADR-014)
- [x] Validation CI (GitHub Actions)
- [x] Git secrets gate — `detect-secrets` hook + baseline + CI step
- [x] Trivy in CI (fail-closed `Security` workflow for digest-pinned images; deploy gated on Security + Validate) + advisory misconfig scans, SARIF
- [x] Real application examples (Homepage v2.3.0 digest-pinned, wave 3 `apps/homepage`; Immich on CloudNativePG, wave 5)
- [x] Architecture Decision Records

**Built but paused — not v1.0.0 deliverables:**
- [~] Vault + External Secrets Operator — code is in the repo and was once deployed, but both are **disabled by default** (`vault.enabled: false`, `eso.enabled: false`). The default secrets path is SOPS + age. Paused under [ADR-017](./adrs/017-vault-paused-sops-default.md); return tracked under [Vault return (ADR-017)](#vault-return-adr-017). `[~]` is not a completion marker — do not read it as shipped.

**Still pending for v1.0 — the complete list:**

This is the same set as [What blocks v1.0.0](#what-blocks-v100), repeated here for checklist readers. It is deliberately short and deliberately non-empty.

- [ ] **Velero restore drill (RTO/RPO validation).** Backup is running; restore has never been executed. This item moved here from v2.0 — it was claimed for v1 while being planned for v2. Evidence per [`docs/restore-verification.md`](./restore-verification.md).

Nothing on this list is a claim of work done. The one item is open.

**Planned for v2.0:**
- [ ] Vault return — re-enable Vault/ESO under ADR-017 (flag flip + restore from the frozen archive)
- [ ] Decoupling & vendor-agnostic ingress — Gateway API BYOD (Envoy Gateway, `GatewayClass: tailscale`; 10→2 devices — 9 per-app `Ingress`es merged into `gateway-envoy`; MagicDNS kept, own-domain split DNS deferred)
- [ ] Compliance & policy (PSA restricted rollout, NetworkPolicy hardening, threat-model doc, Kyverno, CIS Benchmark, RBAC audit, compliance dashboard)
- [ ] Documentation & onboarding (customization guide refresh + e2e)
- [ ] Observability & audit (centralized audit logging)
- [ ] Supply chain & image security (supply chain hardening + Trivy Operator)
- [ ] Automation (secrets rotation via CronJob)
- [ ] Python automation & image security (Ops CLI, infrastructure tests, observability exporter, compliance scanning)

---

## Related documentation

- [Getting Started](./getting-started.md)
- [Customization Guide](./customization-guide.md)
- [Secrets Structure](./secrets-structure.md)
- [Restore verification](./restore-verification.md)
- [Cluster recovery](./cluster-recovery.md)
- [Architecture Decision Records](./adrs/)
