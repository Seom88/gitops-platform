# Changelog

All notable changes to this project will be documented in this file.

Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

This project has never been released. There is no version tag and no published baseline, so there are no "changes" between releases to record — only the current state. Everything below lives under **[Unreleased]** until the first tag is cut. Churn that never reached a user (refactors and bugfixes to code that was never published) is deliberately absent: that is `git log`'s job, not the changelog's.

### Planned (Roadmap)

- **Velero restore drill** — the only item blocking `v1.0.0`. Backup is running; restore is undrilled. See [What blocks v1.0.0](./docs/roadmap.md#what-blocks-v100).
- **Vault return (ADR-017)** — re-enable from the frozen archive when dynamic secrets, auto-rotation, or audit become requirements.
- **Phase 5 — Python automation & image security**: ops CLI (Typer), infrastructure tests (pytest/testinfra), Prometheus exporter, maintenance automation
- **v2.0 — Gateway API BYOD**: consolidate per-app Tailscale Ingresses onto a single `gateway-envoy` device.

## [Unreleased]

### Added

**Cluster foundation**

- **App-of-Apps** — ApplicationSets driven by Helm values, platform local/helm split, per-environment values (`values.yaml` / `values-dev.yaml`)
- **GitOps-only architecture** — ArgoCD and Longhorn installation moved out to the provisioning repo; this repo is a pure App-of-Apps layer consuming cluster prerequisites
- **Longhorn** — distributed block storage (plus local-path for dev environments)
- **SeaweedFS** — S3-compatible object storage; Loki backed by SeaweedFS S3
- **Monitoring stack** — kube-prometheus-stack (Prometheus + Grafana), Loki, and Alloy as a stateless `DaemonSet` log collector
- **cert-manager** — automated TLS certificates
- **Tailscale operator** — secure `.tailnet` ingress for platform services, no public ports
- **Justfile** — task automation: `init-prod`/`init-dev`, port-forwards, status, checks, helm helpers
- **Architecture Decision Records** — decision history with re-entry conditions

**Secrets** — see ADR-017

- **Vault HA** — 3-node Raft with TLS, auto-unseal CronJob, Kubernetes auth, and NetworkPolicies. **Paused, not removed**; the ArgoCD Applications are gated on `vault.enabled`.
- **External Secrets Operator** — per-service `ClusterSecretStore`s with sync-wave ordered configuration. **Paused, not removed**; gated on `eso.enabled`.
- **SOPS + age as the default secrets path** — encrypted-in-git via `<chart>/sops/*.enc.yaml`, `bootstrap/init-sops.sh` + `just secrets-apply`. See `docs/sops.md`.

**Networking** — see ADR-014

- **Cilium 1.20.1 eBPF CNI + Gateway API 1.2.3 + CiliumNetworkPolicy + Hubble** — `ipam: kubernetes`, `kubeProxyReplacement: strict`, `socketLB: hostNamespaceOnly`, `gatewayAPI.enabled`, `cgroup.hostRoot`. Per-namespace `CiliumNetworkPolicy` (gated by `ciliumNetworkPolicy.enabled=true`) with `allow-dns` (kube-dns 53 + `toFQDNs`/`rules.dns`), `allow-egress` (kube-apiserver 443/6443, hubble-relay 4244, intra-ns), `allow-ingress` (intra-ns, tailscale/cluster-gateway, host/remote-node/kube-apiserver probes). Gateway post-DNAT ports 8080/3000/8081. See `docs/networking.md`.
- **Policy coverage: every namespace this repo deploys a workload into.** The `argocd` namespace is a pre-installed cluster prerequisite and `external-secrets` is an upstream chart, both disabled by default — their policy belongs to the provisioning layer. See [Policy coverage](./docs/roadmap.md#policy-coverage-adr-014).

**CI/CD and supply chain**

- **Unified CI (`ci.yaml`)** — `validate.yaml` + `security.yaml` merged into one `CI` workflow (validate + security jobs); `deploy.yaml` gate simplified to a single-workflow lookup. Each push/PR fires 1 CI run + 1 Deploy run instead of 2+2. See `docs/ci-cd.md`.
- **Local CI parity (T1–T3)** — `just validate-images` and `just scan-config` mirror CI locally; pre-commit gains the `inline-image-convention` hook and `detect-secrets` excludes for `Chart.lock` / `*.enc.yaml`. Trivy image scans stay CI-only.
- **Trivy Operator (in-cluster)** — `platform/trivy-operator` (wave 3, `sync-only`): continuous scanning every 6h, results as CRDs + Prometheus metrics; complements CI-time Trivy.
- **detect-secrets** — pre-commit hook + audited `.secrets.baseline` + CI step, fails on new secrets.
- **Renovate** — weekly updates with mandatory manual review for critical components and grouped automerge for the rest.
- **Pre-commit fast gates** — `detect-secrets`, `check-yaml`/`check-json`, `yamllint`, `shellcheck`.

**Storage and applications**

- **Velero** — automated backup (wave 0, S3-compatible RustFS backend, bucket `velero-homelab`, FQDN injected from `gitops/values.yaml`; `daily-full` 02:00, all namespaces, 30d TTL, Longhorn volumes via FsBackup; subchart `12.2.0` / app `1.18.2`). Vault is excluded by policy — Raft restores from Velero corrupt the cluster. **Backup is running; restore is not verified** — no drill has been run. See [What blocks v1.0.0](./docs/roadmap.md#what-blocks-v100).
- **Shared Valkey cache service** — `platform/valkey` (wave 2, `wave-policy: healthy`, namespace `valkey`, PVC 1Gi `longhorn-encrypted`) consumed by immich today and nextcloud later; no `requirepass`, isolation via per-namespace Cilium policy generated from a `consumers` list. immich now points at `valkey.valkey.svc.cluster.local` on server + machine-learning, and its bundled `immich-valkey` subchart resources are disabled and pruned. See [ADR-021](./docs/adrs/021-shared-valkey-cache-service.md).
- **Barman** — Postgres WAL archiving + PITR for stateful app databases.
- **Homepage** — digest-pinned dashboard (wave 3), tailnet suffix centralized via `myDomain` for dashboard links only.
- **Immich + CloudNativePG** — `apps/immich` (wave 5) on the `04-cloudnative-pg` operator (wave 4); library PVC 100Gi→30Gi, DB PVCs 5Gi→2Gi each; `existingClaim` double-nesting fix for the `immich.immich` wrapper/subchart values.
- **Measured storage rightsizing** — Longhorn `default-disk` reserve 30%→15% (~70Gi freed), encrypted volumes enrolled in daily remote backup; Prometheus 15Gi→12Gi, Loki 5Gi→2Gi, SeaweedFS data1 26Gi→10Gi / filer 5Gi→2Gi.
- **Tailscale ingress per chart** — `platform/ts-ingress` chart deleted; each chart owns its own Tailscale Ingress (amends ADR-018).

### Fixed

- **Cilium double-block on Tailscale proxies** — the per-app Ingress migration left all apps unreachable (tailnet healthy, proxies running); proxy traffic allow-listed through Cilium policies.
- **detect-secrets false positive** — `backupTargetCredentialSecret` (a Secret *name*, not a secret) marked `# pragma: allowlist secret`.
