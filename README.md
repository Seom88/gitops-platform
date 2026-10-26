# GitOps Platform

[![Kubernetes](https://img.shields.io/badge/Kubernetes-Distro_Agnostic-blue?style=for-the-badge&logo=kubernetes)](https://kubernetes.io/)
[![GitOps](https://img.shields.io/badge/GitOps-ArgoCD-orange?style=for-the-badge&logo=argo)](https://argoproj.github.io/cd/)
[![Security](https://img.shields.io/badge/Secrets-SOPS_age-blue?style=for-the-badge)](./docs/sops.md)
[![Network](https://img.shields.io/badge/Network-Tailscale-234E5C?style=for-the-badge&logo=tailscale)](https://tailscale.com/)

[![Release](https://img.shields.io/badge/Release-v1.0.0_scope_complete-blue?style=flat-square)](./docs/roadmap.md#what-blocks-v100)
[![CI Status](https://img.shields.io/github/actions/workflow/status/Seom88/gitops-platform/ci.yaml?style=flat-square&label=CI)](https://github.com/Seom88/gitops-platform/actions)
[![Last Commit](https://img.shields.io/github/last-commit/Seom88/gitops-platform?style=flat-square)](https://github.com/Seom88/gitops-platform/commits)
[![License](https://img.shields.io/badge/License-MIT-green?style=flat-square)](LICENSE)

A personal homelab that runs real services on a single mini PC — zero-trust access, encrypted secrets, observable storage and backups. All declarative, all in git.

> This is not a demo cluster. It serves my photos, files, dashboards and backups every day, and it is the proof of how I design, ship and operate a platform. If you hire platform engineers, start with the [five-minute tour](#five-minute-tour-for-recruiters).

## Five-minute tour for recruiters

1. [What this proves I can do](#what-this-proves-i-can-do) — the skill-to-evidence map.
2. [`docs/skills-demonstrated.md`](./docs/skills-demonstrated.md) — the long version, with links to the code and decisions behind each claim.
3. [`docs/features-deep-dive.md`](./docs/features-deep-dive.md) — how the platform actually works.
4. [`docs/adrs/`](./docs/adrs/) — 26 decision records, including the ones where I chose *not* to ship something (Vault paused, single-node tradeoff).
5. [`docs/cluster-recovery.md`](./docs/cluster-recovery.md) — the restore runbook, including what went wrong in the immich pilot.

## In 30 seconds

- **What it is:** A personal homelab built as an App-of-Apps GitOps layer on Kubernetes. With the cluster prerequisites in place (ArgoCD and Cilium), one idempotent command bootstraps the repository-managed networking integration, storage, observability, secrets and apps.
- **Where it runs:** one Lenovo ThinkCentre M920q mini PC (`aleph`) — 6C/12T i7-8700T, 32 GiB RAM — running single-node k3s on AlmaLinux. A small TrueNAS VM on the same box hosts the S3 store used by Loki and Velero.
- **What it runs today:** Homepage, Immich (photos on CloudNativePG), Nextcloud + Collabora (files on CloudNativePG + shared Valkey cache), Prometheus + Grafana + Loki, Longhorn, Velero backups to S3.
- **How it's secured:** Tailscale per-app ingress (no public ports), SOPS + age encrypted secrets in git, Cilium network policies, Trivy + secret scanning in CI.
- **Release state:** v1.0 scope is deployed and working. Manual Velero restore tested Oct 2026; formal clean-cluster drill deferred to v2.0. Single source of truth: [`docs/roadmap.md`](./docs/roadmap.md).

## Recruiter snapshot

This project demonstrates more than Kubernetes configuration. It shows how I design and operate a small production-like platform under real constraints:

| Signal | Evidence in this repository |
|---|---|
| **Platform engineering** | Layered Helm charts, an ArgoCD App-of-Apps, dependency-aware sync waves and custom health checks |
| **Security engineering** | SOPS + age secrets, Tailscale-only ingress, Cilium identity policies, RBAC and CI secret/image scanning |
| **Reliability engineering** | Longhorn persistence, CloudNativePG with Barman, Velero backups to external S3, and a restore already exercised |
| **Operational judgement** | Vault intentionally paused, single-node limits documented, and the formal restore drill tracked as an explicit gap |
| **Developer experience** | Idempotent `just` workflows, local CI parity, Renovate, ADRs and a least-privilege AI-agent devcontainer |
| **Systems thinking** | Right-sized workloads and solar-aware backup scheduling on a 32 GiB mini PC with no cloud dependency |

The platform is for personal use and runs continuously on my mini PC alongside its supporting services. That is intentional: the repository documents both what works in production for this homelab and the limits that would need to change before calling it a multi-node or enterprise platform.

## How it fits together

```mermaid
graph TD
    Admin((Admin)) -->|Tailscale Mesh VPN| TS[Tailscale Operator]
    TS -->|per-app ingress, each app at /| Apps[Homepage · Immich · Nextcloud · Grafana · Prometheus]
    ROOT[ArgoCD root<br/>App-of-Apps] --> CERT[cert-manager]
    ROOT --> ESO[external-secrets - paused]
    ROOT --> STORAGE[Longhorn + Velero + RustFS S3]
    ROOT --> SECRETS[SOPS + age - default<br/>Vault - frozen, paused]
    ROOT --> OBS[Monitoring<br/>Prometheus + Grafana + Loki + Alloy]
    ROOT --> DATA[CloudNativePG + Valkey<br/>Immich + Nextcloud]
```

> Networking detail: Cilium 1.20.1 eBPF + Gateway API. See [ADR-014](./docs/adrs/014-cilium-cni-and-identity-networkpolicies.md) and [Networking](./docs/networking.md).

## What this proves I can do

| You need | Proof here |
|----------|------------|
| **Ship GitOps, not YAML soup** | ArgoCD App-of-Apps with sync-wave ordering and custom health checks — [`gitops/templates/`](./gitops/templates/), [ADR-006](./docs/adrs/006-app-health-and-vault-ordering.md) |
| **Handle secrets like prod** | SOPS + age as default path (encrypted in git, applied via `just secrets-apply`); Vault built, frozen and paused by decision — [ADR-017](./docs/adrs/017-vault-paused-sops-default.md), [`docs/sops.md`](./docs/sops.md) |
| **Zero-trust networking** | Tailscale operator, one MagicDNS device per app, Cilium policies per namespace — [ADR-018](./docs/adrs/018-per-app-tailscale-ingress.md) |
| **Own data durability** | Longhorn block + external RustFS S3, Velero daily backups, manual restore already executed — [`docs/cluster-recovery.md`](./docs/cluster-recovery.md) |
| **Be honest about HA** | Pod-level HA (PDBs, multi-replica stateless, snapshots + off-cluster backups). Single-node cluster = node failure is total downtime — [ADR-019](./docs/adrs/019-single-node-bare-metal-migration.md) |
| **Operate it** | Prometheus + Grafana + Loki + Alloy, CI lint/render/scan gates, Renovate weekly updates — [`docs/ci-cd.md`](./docs/ci-cd.md) |
| **Use AI agents without handing over the cluster** | Podman devcontainer with masked secrets, a read-only prod ServiceAccount and no container socket — [ADR-026](./docs/adrs/026-devcontainer-ai-agents.md), [`docs/devcontainer.md`](./docs/devcontainer.md) |
| **Operate inside real constraints** | Solar-aware backup window, Kepler RAPL energy metrics and right-sized requests on a 32 GiB node — [ADR-025](./docs/adrs/025-solar-energy-aware-operations.md) |

Full breakdown: [`docs/skills-demonstrated.md`](./docs/skills-demonstrated.md) · Decisions: [`docs/adrs/`](./docs/adrs/)

## The hardware

It is deliberately small: one used mini PC, one power budget, no cloud bill.

| | |
|---|---|
| **Host** | Lenovo ThinkCentre M920q, Intel i7-8700T (6C/12T), 32 GiB RAM, Intel UHD 630 |
| **OS / Kubernetes** | AlmaLinux 10.2, single-node k3s v1.36.5, containerd |
| **Storage** | Local disk through Longhorn (1 replica); RustFS S3 in a 6 GiB / 6 vCPU TrueNAS VM |
| **Power** | 200 W solar panel + 768 Wh battery; the backup window follows the solar curve ([ADR-025](./docs/adrs/025-solar-energy-aware-operations.md)) |
| **Network** | Tailscale mesh, no public ingress; Cilium eBPF inside the cluster |
| **Location** | Bogotá, Colombia |

Everything below runs on that one box. Node failure is total downtime — the project is explicit about that tradeoff in [ADR-019](./docs/adrs/019-single-node-bare-metal-migration.md).

## Tech stack

| Layer | Component | State |
|-------|-----------|-------|
| Hardware | Lenovo ThinkCentre M920q — i7-8700T (6C/12T), 32 GiB RAM, single node `aleph` | Running |
| Orchestration | Kubernetes 1.27+ (this lab: k3s v1.36.5 on AlmaLinux 10.2), ArgoCD 2.8+ pre-installed | Ready |
| Secrets | SOPS + age (default) · Vault v1.15+ (frozen, disabled by default) | Deployed / Paused |
| Networking | Cilium 1.20.1 eBPF, Tailscale Operator, cert-manager | Deployed |
| Storage | Longhorn chart 1.13.0 (1 replica), RustFS S3 external (`loki`, `velero-homelab` buckets) | Deployed |
| Data | CloudNativePG, Valkey shared cache | Deployed |
| Apps | Homepage, Immich, Nextcloud | Deployed |
| Observability | Prometheus + Grafana + Loki + Alloy DaemonSet, Trivy Operator, Kepler energy exporter (RAPL watts, ADR-025) | Deployed |
| Backups | Velero 1.18.2 — daily full (solar-window aligned, 18:00 UTC = 13:00 COT, ADR-025), manual restore verified | Backup OK · formal drill → v2.0 |

## Run it

Assumes a running cluster with ArgoCD already installed. Provisioning the mini PC and k3s is out of scope for this repo.

```bash
# 1. Clone and configure
git clone https://github.com/Seom88/gitops-platform.git
cd gitops-platform
cp .env.example .env  # fill in Tailscale + S3 keys — or: just secrets-init

# 2. Bootstrap (idempotent — safe to rerun)
just init-prod   # prod — or: just init-dev

# 3. Check health
just status-cluster
kubectl get applications -n argocd

# 4. Open dashboards (via Tailscale, or port-forward locally)
kubectl port-forward -n monitoring svc/grafana 3000:80
```

Prefer to keep AI agents away from the cluster? `just dev-up` starts the Podman devcontainer described in [`docs/devcontainer.md`](./docs/devcontainer.md) — same repo, masked secrets, read-only prod access.

Full walkthrough: [`docs/getting-started.md`](./docs/getting-started.md) · Forking it: [`docs/customization-guide.md`](./docs/customization-guide.md)

Requirements: Kubernetes 1.27+, ArgoCD 2.8+, kubectl, helm 3.12+, [just](https://github.com/casey/just), Tailscale account (free tier works). The devcontainer additionally needs Podman and the devcontainer CLI.

## Project structure

```
gitops-platform/
├── bootstrap/       # init-gitops.sh — idempotent GitOps bootstrap
├── gitops/          # Root App-of-Apps chart (values.yaml + values-dev.yaml)
├── platform/        # First-party charts: vault, monitoring, ts-operator,
│                    #   longhorn, velero, valkey, trivy-operator, kepler,
│                    #   s3-bucket-lib
├── apps/            # homepage, immich, nextcloud
├── docs/            # guides + adrs/ (26 decisions and counting)
├── odd/tasks/       # feature specs and decision logs
├── .devcontainer/   # Podman devcontainer for AI agents (least privilege)
├── .github/workflows/ # ci.yaml (lint+scan) — CI never touches the cluster; deploys are ArgoCD pull
├── justfile         # init-prod/dev, secrets-apply, validate, scan, status-cluster
├── renovate.json    # weekly dependency updates
└── CHANGELOG.md     # release history
```

## Roadmap & status

v1.0 scope is **deployed** — not tagged yet. Nothing open except the tag itself; formal restore drill moved to v2.0.

| Phase | Status |
|-------|--------|
| Phase 1 — Foundation (bootstrap, ArgoCD, TLS, Tailscale, ADRs) | ✅ Complete |
| Phase 2 — Automation & Observability (monitoring, CI/CD, Renovate) | ✅ Complete |
| Phase 3 — Storage & Scale (Longhorn, RustFS, Velero backup + manual restore) | ✅ Complete |
| Phase 4 — Hardening & DX (Trivy, secret scan, SOPS-default, real apps) | ✅ Complete |
| Phase 5 — Python ops layer | → v2.0 |

Details: [`docs/roadmap.md`](./docs/roadmap.md)

## Docs

- [Skills Demonstrated](./docs/skills-demonstrated.md) — skill-to-evidence map, written for recruiters
- [Roadmap & Status](./docs/roadmap.md) — what is deployed, what comes next
- [Getting Started](./docs/getting-started.md) — end-to-end bootstrap
- [Features Deep Dive](./docs/features-deep-dive.md) — system design per component
- [CI / CD](./docs/ci-cd.md) — pipelines, gates, local mirrors
- [Networking](./docs/networking.md) — Cilium, Gateway API, policies
- [SOPS + age](./docs/sops.md) — default secrets workflow
- [Cluster Recovery](./docs/cluster-recovery.md) — backup & restore runbook
- [Customization](./docs/customization-guide.md) — fork and adapt
- [Devcontainer](./docs/devcontainer.md) — isolated AI agent environment
- [ADRs](./docs/adrs/) — why each key decision was made

## Work with me

Found a bug? → [Issues](https://github.com/Seom88/gitops-platform/issues) · Have an idea? → [Discussions](https://github.com/Seom88/gitops-platform/discussions) · Proof of skills → [`docs/skills-demonstrated.md`](./docs/skills-demonstrated.md) · Reach me → [GitHub @Seom88](https://github.com/Seom88)

---
⭐ If this saved you time, a star helps more than you think.
