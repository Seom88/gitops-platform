# ADR-003: Move ArgoCD and Longhorn to the Infra Repository

**Status:** Accepted · **Date:** 2026-08-18

## Context

Historically, this repository's bootstrap pipeline installed cluster prerequisites itself:

1. **`infra/init-infra.sh`** — node-level setup, including local dev-cluster configurations, the Talos schematic (system extensions), and Longhorn manifests (namespace, StorageClass, Helm values)
2. **`bootstrap/01-init-gitops.sh`** — installed ArgoCD via Helm from `platform/argocd/values.yaml` before syncing anything

This mixed **provisioning concerns** (installing cluster and platform prerequisites) with **GitOps concerns** (declaring the desired cluster state) in a single repository. The repo also claimed multi-environment support, which required environment auto-detection hacks across the scripts.

A hidden hard dependency existed: the ArgoCD chart with `redis-ha` enabled requires PersistentVolumeClaims for its Redis queue, and Talos ships no PVC provisioner — so storage must exist **before** ArgoCD is installed. That ordering was imperative (a script step) and invisible in the GitOps flow: nothing in the declarative state encoded "you need a StorageClass before ArgoCD can come up healthy."

## Options Considered

### Option A — Keep both in the GitOps repo

Keep the existing pipeline: the bootstrap script installs Longhorn, waits for the CSI driver, then installs ArgoCD before deploying the App-of-Apps.

**Pros:** Single repository, single workflow, no cross-repo coordination.

**Cons:** Provisioning concerns stay mixed with GitOps concerns. The scripts remain imperative and environment-dependent. The storage → ArgoCD ordering stays implicit and invisible in the declarative state.

### Option B — Move both to the companion infra repo's `platform/` Terraform root (SELECTED)

Move Longhorn and ArgoCD into `infra-talos-homelab`'s `platform/` Terraform root, applied before any GitOps sync.

**Pros:** Clean responsibility separation — provisioning belongs with the cluster, declarative apps belong in the GitOps layer. The ordering problem becomes an infrastructure dependency instead of a script sequence. This repo becomes distro-agnostic.

**Cons:** Bootstrap becomes a two-step process (infra `platform/` apply, then GitOps bootstrap). Dev clusters must also provide Longhorn + ArgoCD.

### Option C — Move only Longhorn, keep ArgoCD bootstrap in this repo

Move storage to the infra repo but keep the ArgoCD Helm install in `bootstrap/01-init-gitops.sh`.

**Pros:** Removes the storage ordering problem from this repo; the bootstrap still installs its own GitOps engine, preserving a single-workflow feel.

**Cons:** The GitOps repo still installs its GitOps engine, blurring the ownership boundary. Provisioning and GitOps concerns remain mixed. The repo would still need cluster-aware logic to find the cluster before installing ArgoCD.

## Decision

**Option B: Move Longhorn and ArgoCD to the companion infra repository.**

Both are provisioned by `infra-talos-homelab`'s `platform/` Terraform root, applied **before** any GitOps sync, in this order:

1. Wait for nodes to be Ready
2. Longhorn Helm chart 1.12.1 in `longhorn-system` (namespace with PSA privileged labels)
3. Wait for the Longhorn CSI driver to become ready
4. Apply the additional StorageClass `longhorn-prod` (ReclaimPolicy Retain, diskSelector `ssd,nvme`, 3 replicas, migratable)
5. ArgoCD Helm chart `argo-cd` 9.5.13 in `argocd` (values enable `redis-ha`, which requires PVCs)

Longhorn and ArgoCD become **declared prerequisites** of this repository. This repo becomes distro-agnostic: its bootstrap script no longer installs any cluster or platform prerequisite — it only deploys the root App-of-Apps and configures Vault.

The motivation for the move is to keep this repository as **GitOps-only as possible**: the GitOps layer declares desired cluster state and provisions nothing. It is a question of repository responsibility, not of kubectl availability, cluster access, or secrets.

It also keeps the provisioning path free to evolve. In the future, for cloud and Ansible practice, the infra repo may switch from Talos to a conventional distribution configured with Ansible, or consume cloud IaC resources directly (managed Kubernetes or plain VMs) — and this GitOps layer stays untouched, because it only depends on a CNCF-compliant cluster with the declared prerequisites.

## Rationale

1. **Keep the GitOps repo as GitOps-only as possible.** Provisioning and platform prerequisites belong with the cluster; the GitOps layer only declares desired state and runs no provisioning. Moving ArgoCD and Longhorn out removes the last imperative install steps from this repo's pipeline. This is a repository-responsibility decision — it has nothing to do with kubectl availability or this repo's secrets.

2. **Ordering as infrastructure, not script steps.** The dependency chain (storage → CSI → ArgoCD) is now encoded as Terraform resource dependencies instead of imperative script steps that must be manually sequenced and reviewed for ordering.

3. **Distro-agnostic GitOps layer.** This repo now works on any CNCF-compliant cluster that provides the prerequisites. No environment auto-detection.

4. **Completes the existing split.** Terraform provisioning already lived in the infra repo. Moving the remaining bootstrap responsibilities (Longhorn + ArgoCD) finishes the two-repo ownership boundary.

5. **Future provisioning paths stay unconstrained.** Keeping provisioning in the infra repo lets the cluster stack evolve independently of the GitOps layer — for example a conventional distribution provisioned with Ansible, or cloud IaC consuming managed Kubernetes/VM resources directly — without changing how applications are declared here.

## Consequences

- **Positive:** Single responsibility per repo — provisioning in the infra repo, declarative apps in the GitOps repo.
- **Positive:** Explicit prerequisite contract — this repo declares what it needs (Longhorn storage, ArgoCD) instead of installing it.
- **Positive:** No environment auto-detection hacks.
- **Negative:** Two-step bootstrap — apply the infra `platform/` root first (`just tf-platform-apply` in the infra repo), then bootstrap GitOps.
- **Negative:** Dev clusters must also provide Longhorn + ArgoCD (infra `just tf_env=dev tf-platform-apply` or equivalent) before this repo can be bootstrapped.

## Files

### This repository — gitops-platform

| Action | File |
|--------|------|
| Deleted | `infra/` — `init-infra.sh`, local dev-cluster configs, Longhorn manifests, Talos schematic |
| Deleted | `platform/argocd/values.yaml` |
| Deleted | `docs/k3s-install.md` — distro-specific install guide |
| Updated | `bootstrap/01-init-gitops.sh` — removed ArgoCD/Longhorn install + Longhorn prompt |
| Updated | `README.md` — distro-agnostic framing, prerequisites |
| Updated | `justfile` — removed dev-cluster and init-infra recipes |
| Updated | `docs/getting-started.md` — prerequisites, bootstrap flow |
| Updated | `docs/customization-guide.md` — fork prerequisites |

### Infra repository — infra-talos-homelab

| Action | File |
|--------|------|
| Created | `platform/main.tf` |
| Created | `platform/providers.tf` |
| Created | `platform/variables.tf` |
| Created | `platform/values/argocd/values.yaml` |
| Created | `platform/values/longhorn/longhorn-namespace.yaml` |
| Created | `platform/values/longhorn/longhorn-storageclass.yaml` |
| Created | `platform/values/longhorn/longhorn-values.yaml` |