# Skills Demonstrated

This document outlines the technical and operational skills demonstrated by the `gitops-platform` project, with specific evidence and links to implementation details.

---

## 🏗️ Enterprise Architecture & Design

**Skills:**
- Multi-layer architecture design (Infrastructure → Platform → Applications)
- Declarative infrastructure-as-code thinking
- Component coupling and dependency ordering
- Production-grade pattern implementation

**Evidence:**
- **App-of-Apps pattern** — See [`gitops/Chart.yaml`](../gitops/Chart.yaml) and [`gitops/templates/apps/`](../gitops/templates/apps/) for wave-ordered deployments
- **Wave ordering** — Custom Application health probes (ADR-006) gate each wave on `Synced + Healthy` (cert-manager before `velero`, valkey before `immich`/`nextcloud`, CloudNativePG before its user apps; Vault is paused per ADR-017)
- **CSI readiness gates** — Longhorn deployed as wave -1 (ADR-005) to ensure storage is available before stateful workloads
- **Architecture Decision Records** — See [`docs/adrs/`](./adrs/) documenting key choices and tradeoffs
- **Multi-environment support** — `values.yaml` (prod) and `values-dev.yaml` (dev branch) for declarative environment differences

**What Recruiters See:**
You understand how to build systems that scale. This isn't just installing tools — it's composing them intelligently with dependencies, health checks, and safety gates.

---

## 🔐 Secrets Management & Security

**Skills:**
- HashiCorp Vault HA operations and design
- Kubernetes auth methods
- SOPS + age encryption in git (default secrets path — ADR-017)
- External Secrets Operator (paused with Vault — ADR-017)
- Secret rotation and lifecycle management
- Least-privilege access controls (RBAC, per-service ClusterSecretStores)
- Zero-trust networking principles
- TLS certificate automation

**Evidence:**
- **Vault HA Setup (paused, ADR-017)** — 3-node Raft cluster with TLS, auto-unseal via CronJob; chart frozen in `main`, Applications gated on `vault.enabled: false` (server replica count currently 1 per ADR-019). SOPS + age is the live secrets path. See [`platform/vault/templates/`](../platform/vault/templates/) and [`bootstrap/init-sops.sh`](../bootstrap/init-sops.sh)
- **External Secrets Operator (paused, ADR-017)** — Per-service ClusterSecretStores with sync-wave ordering; gated on `eso.enabled: false`. See [`platform/vault/templates/clustersecretstore.yaml`](../platform/vault/templates/clustersecretstore.yaml)
- **Kubernetes Auth** — Vault auth configured per namespace. Bootstrap script handles initial setup at [`bootstrap/init-gitops.sh`](../bootstrap/init-gitops.sh) (lines for auth method config)
- **Auto-Unseal** — CronJob that unseals Vault on node restart (raft recovery). See [`platform/vault/templates/autounseal-cronjob.yaml`](../platform/vault/templates/autounseal-cronjob.yaml)
- **Cert-Manager Integration** — TLS certificates issued and renewed automatically for Vault and services. See [`platform/vault/templates/`](../platform/vault/templates/)
- **Tailscale Zero-Trust** — Mesh VPN for secure ingress without exposing ports. See [`platform/ts-operator/`](../platform/ts-operator/) and ADR-001

**What Recruiters See:**
You can design and operate production secrets management systems. Vault is enterprise-grade; implementing it from scratch (not just installing) shows deep understanding of security patterns.

---

## 🚀 GitOps & Declarative Deployment

**Skills:**
- ArgoCD Application lifecycle management
- Helm templating and values-driven deployments
- Git-driven state management
- Sync-wave orchestration for dependency ordering
- Custom Application health checks
- Dry-run validation and preview

**Evidence:**
- **ArgoCD App-of-Apps** — Root application deploying platform apps via sync-waves. See [`gitops/templates/root-prod-app.yaml`](../gitops/templates/root-prod-app.yaml)
- **Helm Charts** — Each platform component (Vault, Monitoring, Tailscale) packaged as reusable Helm charts. See [`platform/`](../platform/) directory
- **Values-Driven Config** — Environment-specific values (`values.yaml` for prod, `values-dev.yaml` for dev) drive all deployments. See [`gitops/values.yaml`](../gitops/values.yaml) and [`gitops/values-dev.yaml`](../gitops/values-dev.yaml)
- **Sync-Wave Ordering** — Applications ordered deterministically via `argocd.argoproj.io/sync-wave` annotations and custom health checks. See [`docs/adrs/006-app-health-and-vault-ordering.md`](./adrs/006-app-health-and-vault-ordering.md)
- **Health Probes** — Custom Lua logic for ArgoCD health checks (wave dependency). See [`platform/vault/templates/`](../platform/vault/templates/) for Vault health checks
- **Bootstrap Script** — Idempotent bootstrap that deploys the root app and configures Vault. See [`bootstrap/init-gitops.sh`](../bootstrap/init-gitops.sh)

**What Recruiters See:**
You understand GitOps as a paradigm, not just a tool. Sync-wave ordering and health probes show operational sophistication.

---

## 🌐 Zero-Trust Networking & Observability

**Skills:**
- Cilium eBPF CNI (kubeProxyReplacement strict) + Gateway API 1.2.3
- Identity-aware CiliumNetworkPolicy (endpointSelector default-deny, toFQDNs/rules.dns, toEntities)
- Hubble observability (relay 4244/4245, `hubble observe`)
- Tailscale Operator integration
- Network policies and RBAC
- Ingress as a security boundary
- Prometheus metrics collection and dashboarding
- Log aggregation and correlation (Loki + Grafana Alloy, LogQL, Explore)
- Kubernetes log collection at scale (DaemonSet, `discovery.kubernetes` → `loki.source.kubernetes` → `loki.write`)
- Custom observability exporting

**Evidence:**
- **Tailscale Integration** — Mesh VPN operator (wave `-2`) + per-app Ingresses owned by each chart via `tailscaleIngress` values (one MagicDNS device per app, each at `/` root). See [`platform/ts-operator/`](../platform/ts-operator/) and ADRs 001/018
- **Platform Ingress Templates** — Per-chart Ingress pattern (each chart renders its own `tailscale-ingress.yaml` → own device; orphan `argocd`/`hubble` live in `ts-operator/templates/infra/`). See [`platform/vault/templates/tailscale-ingress.yaml`](../platform/vault/templates/tailscale-ingress.yaml)
- **Network Policies** — Identity-aware `CiliumNetworkPolicy` (`cilium.io/v2`) across the 10 charts that render policies (`vault`, `velero`, `longhorn`, `monitoring`, `trivy-operator`, `ts-operator`, `valkey`, `homepage`, `immich`, `nextcloud`) with allow-dns / allow-egress / allow-ingress (eBPF, kubeProxyReplacement strict, Hubble 4244/4245). See [`platform/*/templates/cilium-networkpolicies.yaml`](../platform/vault/templates/cilium-networkpolicies.yaml) (each gated by `ciliumNetworkPolicy.enabled=true`; Cilium 1.20.1, Gateway API 1.2.3). Legacy `networking.k8s.io/v1` `networkpolicy.yaml` retained for non-Cilium clusters
- **Monitoring Stack** — Prometheus (metrics), Grafana (dashboards), Loki (SingleBinary + external RustFS S3 + gateway) + Alloy (stateless DaemonSet log collector via `discovery.kubernetes` → `loki.source.kubernetes` → `loki.write` to `http://monitoring-loki-gateway.monitoring.svc.cluster.local/loki/api/v1/push` with `X-Scope-OrgID: fake`; no PVC, RBAC auto-created; replaces Promtail — deprecated). See [`platform/monitoring/`](../platform/monitoring/) and [`platform/monitoring/values.yaml`](../platform/monitoring/values.yaml) (`loki` + `alloy` blocks, chart `alloy:1.12.1`)
- **Vault Metrics Export** — Prometheus endpoints for Vault health, sealed state, replication status
- **Log Aggregation** — Loki with external RustFS S3 backend for centralized logging, shipped by Alloy. Grafana Explore + LogQL and dashboard Logs panels. See [`platform/monitoring/templates/loki-datasource.yaml`](../platform/monitoring/templates/loki-datasource.yaml)

**What Recruiters See:**
Zero-trust isn't just a buzzword for you — you've implemented it. Metrics collection and observability show maturity in ops thinking.

---

## 📦 Storage & High-Availability

**Skills:**
- Distributed storage system design
- Longhorn CSI integration
- S3-compatible object storage architecture
- Persistent volume management
- Snapshot and backup strategies
- HA database design (Raft consensus)

**Evidence:**
- **Longhorn Deployment** — Wave -1 app with CSI readiness gates. See [`gitops/templates/platform/-1-longhorn.yaml`](../gitops/templates/platform/-1-longhorn.yaml) and ADR-005
- **Longhorn Node Prep** — Nodes provide `iscsi-tools` and kubelet extraMounts for `/var/lib/longhorn`
- **External S3** — RustFS as externalized object storage for backups and logs. See [`docs/rustfs-iam.md`](../rustfs-iam.md)
- **Vault Raft HA (paused, ADR-017)** — 3-node consensus design for high-availability secrets; currently gated off (single-replica server on the 1-node cluster, ADR-019). See [`platform/vault/templates/statefulset.yaml`](../platform/vault/templates/statefulset.yaml)
- **Persistent Volume Management** — Applications using Longhorn PVCs for state. See Vault StatefulSet configuration

**What Recruiters See:**
You understand how stateful workloads actually work in Kubernetes. CSI, snapshots, and HA quorum aren't theoretical.

---

## 🔄 CI/CD & Automation

**Skills:**
- GitHub Actions workflow design
- Validation and testing strategies
- Continuous deployment from CI success (no manual approval gate)
- Dependency management with Renovate
- Automated testing and lint checks
- Local mirrors of CI logic

**Evidence:**
- **GitHub Actions** — Unified `ci.yaml` (validate + security jobs: helm lint/template, image-convention, detect-secrets, ShellCheck, Trivy images + misconfig with SARIF). CI never touches the cluster — deploys are GitOps pull via ArgoCD. See [`.github/workflows/`](../.github/workflows/)
- **CI Workflow** — Single `CI` run per push/PR. See [`.github/workflows/ci.yaml`](../.github/workflows/ci.yaml) and [`docs/ci-cd.md`](./ci-cd.md)
- **GitOps pull deploys** — ArgoCD root app self-manages (automated + prune + selfHeal); break-glass bootstrap/secrets via `just init-prod` / `just secrets-apply`. See [`docs/ci-cd.md`](./ci-cd.md)
- **Renovate Configuration** — Weekly dependency updates with manual review for critical components. See [`renovate.json`](../renovate.json)
- **Local Validation** — `just validate` / `just validate-images` / `just scan-config` mirror CI checks offline. See [`justfile`](../justfile)
- **Dry-Run** — `--validate` flag on bootstrap script for preview. See [`bootstrap/init-gitops.sh`](../bootstrap/init-gitops.sh)

**What Recruiters See:**
You know how to build safe, testable deployment pipelines. Fail-closed image scanning, secrets detection, and local CI mirrors show production thinking.

---

## 🛠️ Infrastructure-as-Code & Modularity

**Skills:**
- Helm chart code organization (DRY, reusable charts)
- Chart templating and Helm best practices
- YAML structure and conventions
- Configuration management across environments
- Documentation-driven code

**Evidence:**
- **Helm Chart Structure** — Each platform component follows standard chart layout with templates, values overrides. See [`platform/`](../platform/)
- **Kustomization** — Values-driven templating for env-specific overrides. See `values.yaml` vs `values-dev.yaml`
- **Reusable Templates** — Ingress pattern, certificate templates, NetworkPolicy templates reused across apps
- **ADR Documentation** — Each architectural decision documented with rationale. See [`docs/adrs/`](./adrs/)

**What Recruiters See:**
You write code that's maintainable and reusable. This isn't spaghetti configuration.

---

## 📚 Technical Communication

**Skills:**
- Architecture documentation (MADRs)
- Operational runbooks and guides
- Technical decision-making and tradeoffs
- README/doc quality showing technical depth
- Clear explanation of complex systems

**Evidence:**
- **Architecture Decision Records** — 24 ADRs documenting decisions and re-entry conditions (superseded ones kept: ADR-004 → ADR-010, ADR-008 → ADR-024, ADR-012 → ADR-018). See [`docs/adrs/`](./adrs/)
- **Getting Started Guide** — End-to-end walkthrough for new users. See [`docs/getting-started.md`](./getting-started.md)
- **Customization Guide** — Forking instructions with dependency management. See [`docs/customization-guide.md`](./customization-guide.md)
- **Secrets Structure** — Documentation of Vault secret organization. See [`docs/secrets-structure.md`](./secrets-structure.md)
- **README Quality** — Clear, structured, links to deeper docs. See main [README.md](../README.md)

**What Recruiters See:**
You can explain technical decisions clearly. This matters for team communication and knowledge transfer.

---

## 🎓 Learning & Continuous Improvement

**Skills:**
- Real-world hands-on learning (not theoretical)
- Problem-solving in complex systems
- Iterative refinement and versioning
- Roadmap planning for growth
- Phase-based delivery

**Evidence:**
- **Roadmap** — Clear phases with completion tracking. See [`docs/roadmap.md`](./roadmap.md)
- **Changelog** — Detailed version history. See [`CHANGELOG.md`](../CHANGELOG.md)
- **Phase 5 Vision** — Post-v1.0 Python automation planned with clear rationale
- **ADR Evolution** — Decisions revisited and updated across 24 records (e.g., ADR-005: Longhorn back to GitOps; ADR-016 abandoned after the 2-node trial; ADR-012 superseded by ADR-018's per-app ingress)

**What Recruiters See:**
This isn't a one-off project. You're building for growth and learning continuously.

---

## � Project Maturity & Roadmap

**Current Status:** v1.0.0 is **not tagged**. Phases 1-4 are deployed; nothing blocks v1.0.0 (the formal Velero restore drill is deferred to v2.0 by decision). The authoritative release state is in [`docs/roadmap.md` § What blocks v1.0.0](./roadmap.md#what-blocks-v100). This file does not carry its own version string.

**What's Planned Next:**
- **Velero Restore Drills** — formal clean-cluster RTO/RPO validation (Velero on RustFS S3 `velero-homelab`; Loki on RustFS S3 `loki`)
- **v2.0** — Vault return (ADR-017), Gateway API BYOD ingress consolidation, compliance/policy work, Phase 5 Python ops layer (CLI automation, infrastructure tests, custom metrics)

See [Roadmap](./roadmap.md) for detailed phase breakdown and timeline.

---

**To explore this project:** Visit [Getting Started](./getting-started.md) or see the full [Feature Breakdown](./features-deep-dive.md).
