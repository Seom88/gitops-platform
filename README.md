# GitOps Platform

[![Kubernetes](https://img.shields.io/badge/Kubernetes-(Distro--Agnostic)-blue?style=for-the-badge&logo=kubernetes)](https://kubernetes.io/)
[![GitOps](https://img.shields.io/badge/GitOps-ArgoCD-orange?style=for-the-badge&logo=argo)](https://argoproj.github.io/cd/)
[![Security](https://img.shields.io/badge/Security-HashiCorp_Vault-blue?style=for-the-badge&logo=vault)](https://www.vaultproject.io/)
[![Network](https://img.shields.io/badge/Network-Tailscale-234E5C?style=for-the-badge&logo=tailscale)](https://tailscale.com/)

[![Release](https://img.shields.io/badge/Release-v1.0.0%20pending-blue?style=flat-square)](./docs/roadmap.md#what-blocks-v100)
[![CI Status](https://img.shields.io/github/actions/workflow/status/Seom88/gitops-platform/ci.yaml?style=flat-square&label=CI)](https://github.com/Seom88/gitops-platform/actions)
[![Last Commit](https://img.shields.io/github/last-commit/Seom88/gitops-platform?style=flat-square)](https://github.com/Seom88/gitops-platform/commits)
[![License](https://img.shields.io/badge/License-MIT-green?style=flat-square)](LICENSE)
[![Status](https://img.shields.io/badge/Status-Active%20Development-brightgreen?style=flat-square)](#-roadmap--status)

Production-grade **GitOps reference implementation** that demonstrates enterprise DevSecOps patterns on any CNCF-compliant Kubernetes cluster. Combines zero-trust networking (Tailscale), secrets management (SOPS + age by default, Vault HA paused), and declarative deployments (ArgoCD).

## � Quick Navigation

- [Why This Matters](#-why-this-matters) — Career relevance for recruiters
- [Skills Demonstrated](#-skills-demonstrated) — What this proves you can build
- [Highlights](#-highlights) — Key features at a glance
- [Architecture](#-architecture) — System design
- [Quick Start](#-quick-start) — Get up and running
- [Roadmap](#-roadmap--status) — Phases and progress
- [Contributing](#-contributing) — How to participate
- **Deep Dives:** [Features](./docs/features-deep-dive.md) · [Getting Started](./docs/getting-started.md) · [Customization](./docs/customization-guide.md)

---

## 💡 Why This Matters

This is **not just another Kubernetes homelab** — it's a reference implementation that demonstrates:

- **Production-grade architecture** — How real DevSecOps teams build secure, scalable systems
- **Enterprise patterns** — secrets management (SOPS + age as the default path; Vault built, frozen and paused per [ADR-017](./docs/adrs/017-vault-paused-sops-default.md)), ArgoCD for GitOps, zero-trust networking via Tailscale
- **Hands-on learning** — Understand distributed systems, Kubernetes operations, and infrastructure automation by running real workloads
- **Career value** — Portfolio that shows you can architect and operate enterprise platforms

**For recruiters:** This demonstrates the ability to design multi-layer systems, understand security fundamentals, and implement industry best practices.

**For your learning:** Fork it, modify it, deploy it — understand production systems by building and troubleshooting them.

---

## 🎓 Skills Demonstrated

| Area | What This Proves | See Also |
|------|------------------|----------|
| **Secrets Management** | SOPS + age as the default path; Vault (Raft, auto-unseal, per-service auth) built and **frozen — disabled by default** (ADR-017) | [`platform/vault/`](./platform/vault/), [ADR-017](./docs/adrs/017-vault-paused-sops-default.md), [Docs](./docs/skills-demonstrated.md#-secrets-management--security) |
| **GitOps & Orchestration** | ArgoCD App-of-Apps, sync-wave ordering, custom health checks | [`gitops/templates/apps/`](./gitops/templates/apps/), [ADR-006](./docs/adrs/006-app-health-and-vault-ordering.md) |
| **Zero-Trust Networking** | Tailscale operator, per-app Ingresses (one MagicDNS device per app, every app at `/` root) | [`platform/ts-operator/`](./platform/ts-operator/), [ADR-001](./docs/adrs/001-tailscale-ingress-placement.md), [ADR-018](./docs/adrs/018-per-app-tailscale-ingress.md) |
| **High-Availability** | **Pod-level** HA: PDBs, multi-replica stateless workloads, Longhorn snapshots + off-cluster S3 backups. **Node-level HA is a property of the cluster, not of this repo** — multi-node Kubernetes HA is not available on the single-node topology (ADR-019); node failure is total downtime. | [ADR-019](./docs/adrs/019-single-node-bare-metal-migration.md), [Features](./docs/features-deep-dive.md#-storage-longhorn--seaweedfs) |
| **Observability** | Prometheus + Grafana + Loki + Alloy (DaemonSet log collector) with Vault metrics | [`platform/monitoring/`](./platform/monitoring/) |
| **Storage & Data** | Longhorn CSI, SeaweedFS S3, persistent volume management | [`platform/seaweedfs/`](./platform/seaweedfs/), [ADR-005](./docs/adrs/005-longhorn-back-to-gitops.md) |
| **Multi-Environment Config** | Prod/dev value pairs, chart validation, CI/CD gates | [`gitops/values.yaml`](./gitops/values.yaml), [`gitops/values-dev.yaml`](./gitops/values-dev.yaml), [CI/CD](./docs/ci-cd.md) |
| **DevSecOps Mindset** | Architecture Decisions documented, roadmap planned, phases tracked | [Roadmap](./docs/roadmap.md), [ADRs](./docs/adrs/) |

**Full skill breakdown:** See [`docs/skills-demonstrated.md`](./docs/skills-demonstrated.md)

---

## ✨ Highlights

- 🔒 **Enterprise Security** — zero-trust networking, per-service RBAC, SOPS + age encrypted-in-git secrets (Vault built and paused by default, ADR-017)
- 🚀 **GitOps Native** — App-of-Apps pattern with wave-ordered dependencies and custom health checks
- 🌐 **Cluster-Agnostic** — Runs on any CNCF-compliant Kubernetes distro
- ⚡ **Production-Ready Patterns** — Demonstrates how real platforms scale secrets, networking, and deployments
- 📊 **Complete Observability** — Prometheus metrics, Grafana dashboards, Loki log aggregation via Alloy (stateless DaemonSet)
- 📦 **Storage Ready** — Longhorn distributed storage + SeaweedFS S3 backend (Loki) / RustFS S3 (Velero)
- 🔄 **Idempotent Bootstrap** — Rerun scripts safely, designed for repeated deployments

## 🏗 Architecture

```mermaid
graph TD
    subgraph "Tailscale Mesh VPN"
        TS[Tailscale Operator]
    end

    subgraph "Kubernetes Cluster (distro-agnostic)"
        direction TB
        CILIUM[Cilium 1.20.1<br/>eBPF kube-system<br/>kubeProxyReplacement strict<br/>Gateway API 1.2.3]
        ROOT[ArgoCD root<br/>App-of-Apps]
        W0A[-1 cert-manager<br/>wave -1 healthy]
        W0B[00 external-secrets<br/>wave 0 healthy]
        W0C[-1 longhorn<br/>wave -1 healthy<br/>CSI-gated]
        W1[01 vault<br/>wave 1 healthy<br/>1 replica, paused by default]
        W2[02 seaweedfs<br/>wave 2 healthy]
        W3[03 monitoring + trivy-operator<br/>wave 3 sync-only<br/>Prometheus + Grafana + Loki + Alloy DaemonSet<br/>owns grafana/prometheus Ingresses]
        W4[04 cloudnative-pg → 05 immich<br/>waves 4-5<br/>PostgreSQL operator + photo app]
        W5[06 nextcloud<br/>wave 6<br/>files app on CNPG + shared valkey (redis db 1)]
        WOP[-1 ts-operator<br/>wave -1<br/>operator + proxy-egress policies<br/>owns argocd/hubble Ingresses]

        CILIUM -.->|CNI + NetworkPolicy| ROOT
        ROOT --> W0A & W0B & W0C
        W0A & W0B & W0C --> W1
        W1 --> W2
        W2 --> W3
        ROOT -.->|wave -1| WOP
    end

    User((Admin)) -->|tailscale| TS
    TS -->|secure ingress| ROOT
    TS -->|secure ingress| Vault
    TS -->|secure ingress| Apps

    ESO -->|ClusterSecretStore| Vault
    Vault -.->|auto-unseal CronJob| Vault
    Cert -.->|TLS certificates| Vault
```

> Cilium CNI + identity-aware policies: see [ADR-014](./docs/adrs/014-cilium-cni-and-identity-networkpolicies.md) and [Networking](./docs/networking.md).

## 🛡 Key DevSecOps Features

- **GitOps Automation** — ArgoCD manages everything declaratively via App-of-Apps. The bootstrap script deploys the root app and configures Vault in one idempotent step.
- **Cluster-Agnostic Platform** — This layer runs on any Kubernetes distro — EKS, GKE, or any CNCF cluster — once ArgoCD is pre-installed.
- **Zero-Trust Networking** — Tailscale operator provides per-app secure ingress (one MagicDNS device per app: `argocd`, `grafana`, `prometheus`, `vault`, `longhorn`, `seaweedfs-s3`, `seaweedfs-admin`, `homepage`, `nextcloud`, `hubble` on `*.lonk-mirfak.ts.net`, each served at `/` root). Every admin access goes through Tailscale mesh VPN. See [ADR-018](./docs/adrs/018-per-app-tailscale-ingress.md).
- **Enterprise Secrets Management** — **SOPS + age is the default path**: encrypted files in git, decrypted and applied by `bootstrap/init-sops.sh` / CI, never decrypted by ArgoCD. Vault (Raft, auto-unseal, per-service ClusterSecretStores) is also in the repo, **frozen and disabled by default** (`vault.enabled: false`, `eso.enabled: false`) per [ADR-017](./docs/adrs/017-vault-paused-sops-default.md); it returns under a flag flip plus a restore from the frozen archive. Vault runs at 1 replica, not a 3-node quorum ([ADR-019](./docs/adrs/019-single-node-bare-metal-migration.md)).
- **Distributed Storage** — Longhorn CSI (wave-0) provides persistent volumes; SeaweedFS adds S3-compatible object storage for logs and backups.
- **Complete Observability** — Prometheus + Grafana + Loki + Alloy stack with Vault, ArgoCD, and cluster metrics (Alloy DaemonSet ships pod logs via `loki.source.kubernetes` → `loki.write` to Loki gateway). All dashboards secured behind Tailscale.
- **Declarative Everything** — Infrastructure, secrets, applications — all defined in git, no imperative commands. Audit trail for compliance.

**For technical deep-dives:** See [`docs/features-deep-dive.md`](./docs/features-deep-dive.md)

## 🛠 Tech Stack

| Layer | Component | Status | Notes |
|-------|-----------|--------|-------|
| **Orchestration** | Kubernetes (any distro) | ✅ Ready | Any CNCF-compliant distribution |
| **GitOps Engine** | ArgoCD v2.8+ | ✅ Ready | Pre-installed on the cluster |
| **Secrets** | SOPS + age (default) · Vault v1.15+ HA paused | ✅ Deployed (SOPS) · ⏸ Paused (Vault) | SOPS + age encrypted-in-git via `just secrets-apply`; Vault frozen at 1 replica, disabled by default (ADR-017, ADR-019) |
| **Secrets Sync** | External Secrets Operator | ⏸ Paused | Per-service ClusterSecretStores (Vault path, disabled by default — `eso.enabled: false`, ADR-017) |
| **Certificates** | cert-manager v1.13+ | ✅ Deployed | Automated TLS for services |
| **Networking (CNI)** | Cilium v1.20.1 (eBPF) | ✅ Deployed | Kube-proxy replacement, Gateway API & CiliumNetworkPolicy |
| **Networking (Ingress)** | Tailscale Operator v1.9+ | ✅ Deployed | Zero-trust ingress (`.tailnet` domains) |
| **Storage (Block)** | Longhorn v1.6+ | ✅ Deployed | Distributed, wave -1 with CSI gates; disk reserve 15% |
| **Storage (Object)** | SeaweedFS v3.6+ | ✅ Deployed | S3-compatible, Loki backend |
| **Database** | CloudNativePG operator | ✅ Deployed | Wave 4, backs Immich |
| **Apps** | Homepage dashboard + Immich | ✅ Deployed | Waves 3/5, per-app Tailscale Ingresses |
| **In-cluster Security** | Trivy Operator | ✅ Deployed | Wave 3, scan every 6h (CRDs + Prometheus) |
| **Monitoring** | Prometheus v2.45+, Grafana v10+, Loki v2.9+ + Alloy chart 1.12.1 | ✅ Deployed | Full observability stack (Prometheus + Grafana + Loki + Alloy DaemonSet) |
| **Backups** | Velero v1.18.2 (chart 12.2.0) | ✅ Backup deployed · ⚠️ Restore unverified | Wave 0, RustFS S3 (`velero-homelab`), daily + hourly schedules. **No restore drill has been run** — see [what blocks v1.0.0](./docs/roadmap.md#what-blocks-v100) |
| **Python Automation** | Typer CLI, pytest, Trivy | 🚧 Phase 5 | Post-v1.0 release (v2.0 roadmap) |

---

## 🏁 Getting Started

This is the **GitOps layer** — it assumes a running cluster with ArgoCD already installed. Cluster provisioning is out of scope here.

### System Requirements

- **Kubernetes 1.27+** (any CNCF-compliant distribution)
- **ArgoCD 2.8+** (pre-installed on cluster)
- **kubectl** and **helm 3.12+**
- **just** (task runner) — [install](https://github.com/casey/just)
- **Tailscale account** (free tier supported) — for secure ingress

### Prerequisites

1. Ensure you have a running Kubernetes cluster with **ArgoCD installed**
2. Cluster networking configured (Tailscale subnet router set up for secure access)
3. `kubeconfig` available locally

### Quick Setup

```bash
# 1. Fork/clone this repo and update repository references
git clone https://github.com/YOUR_USERNAME/gitops-platform.git
cd gitops-platform

# 2. Bootstrap the GitOps layer (deploys root App-of-Apps + configures Vault)
./bootstrap/init-gitops.sh prod

# 3. Verify deployment (watch apps come online)
kubectl get applications -n argocd
just status

# 4. Access dashboards
# Grafana, Prometheus, Vault UI all available via Tailscale
# Use port-forward for local access:
kubectl port-forward -n monitoring svc/grafana 3000:80
```

**Full walkthrough:** See [`docs/getting-started.md`](./docs/getting-started.md)  
**Customization:** See [`docs/customization-guide.md`](./docs/customization-guide.md)

## 📂 Project Structure

```
gitops-platform/
├── bootstrap/               # Bootstrap script (init-gitops.sh)
├── platform/                # Helm charts (Vault, Monitoring, Tailscale, SeaweedFS)
├── gitops/                  # Root App-of-Apps (wave-ordered deployments)
├── apps/                    # User application templates
├── docs/                    # Documentation, ADRs, guides
├── .github/workflows/       # CI/CD pipelines
├── renovate.json            # Dependency update automation
├── justfile                 # Task automation
└── README.md               # This file
```

**Key files:**
- `bootstrap/init-gitops.sh` — Idempotent bootstrap script
- `gitops/Chart.yaml` — Root App-of-Apps meta-chart
- `gitops/templates/apps/` — Platform apps ordered by sync-wave
- `platform/vault/` → `platform/ts-operator/` → ... — Individual platform charts

**Full directory walkthrough:** See [`docs/getting-started.md`](./docs/getting-started.md)

## 📈 Roadmap & Status

**Current Version:** v1.0.0 **not tagged** — see [`docs/roadmap.md`](./docs/roadmap.md#what-blocks-v100) for the authoritative release state. This README does not carry its own version string; the roadmap does.

| Phase | Status | Highlights |
|-------|--------|----------|
| **Phase 1** — Foundation | ✅ Complete | Bootstrap, ArgoCD, cert-manager, Tailscale, ADRs. Vault + ESO built but paused (ADR-017) |
| **Phase 2** — Automation & Observability | ✅ Complete | Prometheus + Grafana + Loki + Alloy (DaemonSet), Renovate, CI/CD gates |
| **Phase 3** — Storage & Scale | 🟡 Backup done, restore unverified | Longhorn ✅, SeaweedFS ✅ (Loki), Velero backup ✅ (RustFS, Wave 0) — **restore drill not run** |
| **Phase 4** — Hardening & DX | 🟡 Partial | Bootstrap guard ✅, status verifier ✅, real apps ✅ (Homepage + Immich/CNPG), SOPS-default ✅ |
| **Phase 5** — Python Automation | 🚧 Planned | Post-v1.0: ops CLI, tests, metrics, image scanning |

**Full roadmap with Phase 5 vision:** See [`docs/roadmap.md`](./docs/roadmap.md)

**What blocks v1.0.0:** the Velero restore drill, and egress policies for the `argocd` / `external-secrets` workloads.

**v2.0 Roadmap:** Python ops layer (Phase 5) post-v1.0

---

## 🤝 Contributing & Collaboration

This project is actively maintained and open to contributions.

### Get Involved

- 🐛 **Found a bug?** → [GitHub Issues](https://github.com/Seom88/gitops-platform/issues)
- ✨ **Have an idea?** → [GitHub Discussions](https://github.com/Seom88/gitops-platform/discussions)
- 📝 **Want to contribute?** → See [CONTRIBUTING.md](./CONTRIBUTING.md) for guidelines
- 🏗️ **Architectural proposals?** → Open a PR with an ADR in [`docs/adrs/`](./docs/adrs/)

### For Recruiters & Team Leads

If you're evaluating DevOps/Platform Engineering talent:

- **Portfolio Evidence:** This repo demonstrates [these specific skills](./docs/skills-demonstrated.md)
- **Technical Communication:** See [ADRs](./docs/adrs/) for architectural thinking
- **Real-World Patterns:** Production-grade implementations, not toy examples
- **Contact:** Connect via [GitHub Profile](https://github.com/Seom88)

---

## 📚 Documentation

- **[Getting Started](./docs/getting-started.md)** — End-to-end bootstrap walkthrough
- **[CI / CD](./docs/ci-cd.md)** — Unified `ci.yaml`, deploy gate, Justfile mirrors, Renovate
- **[Customization Guide](./docs/customization-guide.md)** — Forking and adapting the project
- **[Features Deep Dive](./docs/features-deep-dive.md)** — System design and detailed explanations of each feature
- **[Networking](./docs/networking.md)** — Cilium eBPF, Gateway API & policies
- **[SOPS + age](./docs/sops.md)** — Default secrets workflow (Vault paused)
- **[Cluster recovery](./docs/cluster-recovery.md)** — Backup & restore ([restore runbook](./docs/cluster-recovery.md#2-restore-runbook), [RustFS IAM](./docs/rustfs-iam.md))
- **[Skills Demonstrated](./docs/skills-demonstrated.md)** — What this proves you can build
- **[Roadmap](./docs/roadmap.md)** — Phases, status, and v2.0 vision
- **[Architecture Decision Records](./docs/adrs/)** — Why key decisions were made
- **[Secrets Structure](./docs/secrets-structure.md)** — Vault secret organization (Vault path, paused by default)

---

**Built for learning, production patterns, and DevSecOps career growth.** ⭐ If this helps you, please consider starring the repo!