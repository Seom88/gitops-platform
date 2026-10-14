# Features Deep Dive

Detailed technical explanations of the key features implemented in this project. Use this alongside the README for comprehensive understanding.

---

## 🔐 Secrets Management — SOPS default, Vault paused

> **Current default: SOPS + age** (Vault paused, not deleted — [ADR-017](./adrs/017-vault-paused-sops-default.md)). New secrets ship encrypted in git (`<chart>/sops/*.enc.yaml`), applied out-of-band by `bootstrap/init-sops.sh` (`just secrets-apply`). Full workflow: [SOPS guide](./sops.md).

### What's Implemented

**SOPS + age (live path):**
- Encrypted-in-git secrets — only `data`/`stringData` encrypted, metadata stays readable
- No Helm templating inside `.enc.yaml` (pure YAML) — conditionals live in wrapper templates
- Age key restored from RustFS (`s3://secrets-homelab/sops/keys.txt`), shredded after apply
- CI applies via `deploy.yaml` (installs `sops v3.10.2` first)

**Vault 3-Node High-Availability Cluster** (paused — chart frozen in place):
- HA quorum for fault tolerance — cluster survives 1 node failure
- TLS encryption for client-server and node-to-node communication
- Auto-unseal via CronJob — automatically unseals on pod restart
- Kubernetes auth method — applications authenticate via service account tokens
- External Secrets Operator (ESO) — syncs secrets from Vault → native K8s Secrets
- Per-service ClusterSecretStores — least-privilege per-application access

### Why This Matters

Vault is the industry standard for secrets management. Implementing it from scratch (not just installing) demonstrates:
- Understanding of distributed systems (Raft consensus)
- TLS/PKI knowledge
- Production-grade security patterns
- Kubernetes RBAC integration

### How It Works

1. **Initialization** — Bootstrap script generates Vault init keys, unseals cluster, and configures Kubernetes auth
2. **Secret Storage** — Applications store secrets in Vault (e.g., `secret/app/database/password`)
3. **Sync to K8s** — External Secrets Operator watches Vault, syncs to native Secrets
4. **Pod Injection** — Applications read from K8s Secrets or use Vault agent for direct injection
5. **Auto-Unseal** — CronJob detects sealed pods, unseals them via KMS (backend depends on configuration)

### Key Files

- Configuration: [`platform/vault/Chart.yaml`](../platform/vault/Chart.yaml)
- Templates: [`platform/vault/templates/`](../platform/vault/templates/)
  - StatefulSet (3 replicas): `statefulset.yaml`
  - Network Policies: `networkpolicy.yaml`
  - ClusterSecretStores: `clustersecretstore.yaml`
  - Auto-unseal CronJob: `autounseal-cronjob.yaml`
- Bootstrap: [`bootstrap/init-gitops.sh`](../bootstrap/init-gitops.sh) (Vault init & auth setup)
- ADR: [ADR-002: Vault Config Decentralization](./adrs/002-vault-config-decentralization.md)

---

## 🌐 Zero-Trust Networking with Tailscale

### What's Implemented

**Tailscale Operator** for mesh VPN ingress — one Ingress + device per app:
- One MagicDNS device/hostname per app (`argocd`, `grafana`, `prometheus`, `longhorn`, `seaweedfs-s3`, `seaweedfs-admin`, `homepage`, `hubble`, `vault` on `*.lonk-mirfak.ts.net`; `-dev` suffix in dev), each served at `/` root — no subpath routing — see [ADR-018](./adrs/018-per-app-tailscale-ingress.md)
- No public port exposure — ingress only via Tailscale mesh
- Per-user access control — OAuth scopes integrated with Tailscale
- Subnet routing — cluster pods accessible directly from Tailscale network
- MeshVPN — encrypted point-to-point tunnels between admin device and cluster

### Why This Matters

Zero-trust networking is the modern security boundary model. This replaces:
- ❌ Exposing services on public IPs (insecure)
- ❌ VPN clients requiring manual setup (friction)
- ✅ Tailscale mesh providing cryptographic identity + encryption by default

### How It Works

1. **Operator Installation** — Tailscale operator runs on cluster, creates `Ingress` resources
2. **Annotation-Driven** — Add `tailscale.com/expose: "true"` to Service or Ingress
3. **DNS Magic** — Tailscale assigns `.ts.net` domain based on cluster name
4. **Access Control** — OAuth policy restricts who can access via Tailscale
5. **Secure Ingress** — All traffic encrypted, no firewall rules needed

### Example: Access Grafana

```bash
# No firewall rules, no public IP exposure
# Device must be part of Tailscale network — one device per app, each at root
open https://grafana.lonk-mirfak.ts.net/
open https://argocd.lonk-mirfak.ts.net/
open https://prometheus.lonk-mirfak.ts.net/
```

### Key Files

- Operator deployment: [`platform/ts-operator/Chart.yaml`](../platform/ts-operator/Chart.yaml) (wave `-1`)
- Per-app Ingresses: each chart renders its own `tailscale-ingress.yaml` (one Ingress + device per app)
  - `homepage`, `monitoring` (`grafana` + `prometheus`), `longhorn`, `seaweedfs` (`s3` + `admin`), `vault` — hostnames via `tailscaleIngress` values (`-dev` in dev)
  - Orphans (`argocd`, `hubble`) ship from [`platform/ts-operator/templates/infra/`](../platform/ts-operator/templates/infra/)
- Proxy→backend Cilium egress lives in `ts-operator` as `ts-operator-proxy-egress` (managed-proxy selector); no `ts-ingress` chart remains
- ADRs: [ADR-001: Tailscale Ingress Placement](./adrs/001-tailscale-ingress-placement.md), [ADR-018: Per-App Tailscale Ingresses](./adrs/018-per-app-tailscale-ingress.md) (supersedes ADR-012), [ADR-014: Cilium CNI and Identity-Aware NetworkPolicies](./adrs/014-cilium-cni-and-identity-networkpolicies.md)

---

## 🐝 eBPF Networking & Security with Cilium

### What's Implemented

**Cilium CNI (`v1.20.1`) + Gateway API `v1.2.3` with Identity-Aware NetworkPolicies**:
- **eBPF Kube-Proxy Replacement (strict)** — Service routing and load-balancing in kernel space without iptables; `socketLB: hostNamespaceOnly`, `cgroup.hostRoot: /sys/fs/cgroup`.
- **Identity-Based Segmentation** — Fine-grained `CiliumNetworkPolicy` (`cilium.io/v2`) across 9 charts (`vault`, `longhorn-system`, `seaweedfs`, `monitoring`, `tailscale`, `tailscale-operator`, `velero`, `cert-manager`, `external-secrets`); gated by `ciliumNetworkPolicy.enabled=true`.
- **L7 DNS Visibility & Scoping** — Egress DNS restricted to `kube-system/k8s-app=kube-dns` on UDP/TCP 53 with Cilium L7 DNS rules (`toFQDNs.matchPattern: "*"` + `rules.dns`), blocking DNS-based exfiltration while allowing MagicDNS (`*.ts.net`).
- **Zero-Trust Default Posture** — `endpointSelector: {}` default-deny per namespace; explicit allows for intra-namespace, kube-apiserver (443/6443), and Hubble relay (4244/4245).
- **Observability Integration** — Hubble relay whitelisted (`ports 4244/4245`) for real-time flow tracing (`hubble observe`).

### How It Works

1. **eBPF Datapath vs iptables** — Cilium replaces kube-proxy (`kubeProxyReplacement: strict`) with eBPF programs attached to the kernel. With `ipam: kubernetes`, Cilium owns pod address allocation and service routing end to end.
2. **Policy Lifecycle — 3-Rule Template per Namespace** — Each chart renders `platform/*/templates/cilium-networkpolicies.yaml` (gated by `ciliumNetworkPolicy.enabled`):
   - `allow-dns` — `endpointSelector: {}` + `toEndpoints: {k8s-app: kube-dns, k8s:io.kubernetes.pod.namespace: kube-system}` on port 53 (UDP/TCP) with `toFQDNs: [{matchPattern: "*"}]` and `rules.dns`.
   - `allow-egress` — kube-apiserver (443/6443), `hubble-relay` (4244), intra-namespace (`k8s:io.kubernetes.pod.namespace: <ns>`), plus per-app specifics (e.g., Vault Raft, Longhorn/SeaweedFS storage ports).
   - `allow-ingress` — intra-namespace and `toEntities: {host, remote-node, kube-apiserver}` + `health` probes.
3. **Identity & DNS Details** — Cilium assigns cryptographic endpoint identities (not volatile Pod IPs). Egress uses `toFQDNs` + `rules.dns` for FQDN-aware filtering and `toEntities` (`host`, `remote-node`, `kube-apiserver`) for node-level probes. `kube-apiserver` entity covers the API server regardless of IP.
4. **Hubble Observability** — Hubble parses eBPF flow events. Relay listens on `4244` (gRPC) and `4245` (Hubble UI/health); policies whitelist these ports. Verify flows with `hubble observe -n <ns> --follow` or `hubble observe --verdict DROPPED` to debug silent drops. UI exposed via its own per-chart Ingress at `https://hubble.lonk-mirfak.ts.net` (see ADR-014).
5. **Operational Notes** — New inter-service traffic must be added explicitly to the caller's `cilium-networkpolicies.yaml`. Storage data planes (Longhorn 9500/8000/8500-8503, SeaweedFS 8333/9333) stay unrestricted intra-namespace to avoid attachment deadlocks on ephemeral ports (ADR-014 storage invariant). Renovate automerges Cilium/Gateway API patch updates; Cilium major bumps require manual review.

### Key Files

- Fallback (non-Cilium clusters): `platform/*/templates/networkpolicy.yaml` (`networking.k8s.io/v1`) — retained for non-Cilium clusters, not enforced when Cilium is active
- Cilium (enforced): `platform/*/templates/cilium-networkpolicies.yaml` (9 charts, gated by `ciliumNetworkPolicy.enabled=true`) + `platform/*/values.yaml` (`ciliumNetworkPolicy.enabled: true` default)
- ADRs: [ADR-014: Cilium CNI and Identity-Aware NetworkPolicies](./adrs/014-cilium-cni-and-identity-networkpolicies.md) · [Networking guide](./networking.md)

---

## 🚀 GitOps with ArgoCD App-of-Apps

### What's Implemented

**Declarative Application Lifecycle** via ArgoCD:
- App-of-Apps pattern — root application manages platform apps
- Sync-wave ordering — applications deployed in dependency order (cert-manager → vault → apps)
- Custom health probes — wait for cert-manager before deploying vault
- Idempotent bootstrap — deploy the root app, ArgoCD handles rest
- Multi-environment support — prod/dev values drive configuration

### Why This Matters

GitOps ensures:
- **Reproducibility** — Same git commit always produces same cluster state
- **Auditability** — Every change in git, every deployment traceable
- **Safety** — Dry-run, diff, and approval workflows built-in
- **Scalability** — Add applications by committing YAML, not running imperative commands

### How It Works

1. **Define Apps as YAML** — Each platform app (Vault, Longhorn, Monitoring) defined as ArgoCD `Application` resource
2. **Sync Waves** — Annotate with `argocd.argoproj.io/sync-wave: "0"` to order deployment
3. **Health Checks** — Custom Lua probes wait for dependencies (e.g., cert-manager healthy before vault starts)
4. **Deployment** — ArgoCD watches git, diffs actual vs. desired, applies changes
5. **Root App** — Single `Application` points to `gitops/` Chart, which generates all platform apps

### App Dependency Graph

```
Wave -1 (Healthy required):
  ├── ts-operator    ← Must be healthy; gates 0..5; owns orphan argocd/hubble Ingresses
  ├── cert-manager   ← Must be ready
  └── longhorn       ← Must be healthy + CSI-gated

Wave 0 (Healthy required):
  ├── external-secrets ← Must be ready
  └── velero           ← Backup; bucket-init hook waits for ts.net DNS; NPs scope egress to velero only

Wave 1 (Healthy required):
  └── vault          ← Depends on wave 0 (paused by default — ADR-017; SOPS is the live secrets path)

Wave 2 (Healthy required):
  ├── seaweedfs      ← Depends on wave 1
  └── valkey         ← Shared cache service (namespace valkey); consumed by immich (redis db 0, Bull queues) and nextcloud (redis db 1, cache + locking) over valkey.valkey.svc.cluster.local

Wave 3 (Sync-only):
  ├── monitoring     ← Prometheus + Grafana + Loki (SeaweedFS S3) + Alloy DaemonSet (stateless, RBAC auto); owns grafana/prometheus Ingresses; depends on wave 2
  ├── trivy-operator ← In-cluster scan every 6h (CRDs + Prometheus metrics); complements CI-time Trivy
  └── homepage       ← User app (dashboard); `myDomain` suffix for links only

Wave 4 (Healthy required):
  └── cloudnative-pg ← PostgreSQL operator for apps

Wave 5 (Sync-only):
  └── immich         ← User app on CloudNativePG (library 30Gi×2, DB 3Gi×2) + shared valkey

Wave 6 (Sync-only):
  └── nextcloud      ← User app on CloudNativePG (data 8Gi longhorn-encrypted, DB 3Gi×2) + shared valkey (redis db 1); own Ingress nextcloud.lonk-mirfak.ts.net

No `ts-ingress` chart — deleted; each chart owns its per-app Tailscale Ingress (ADR-018 + consolidation amendment).
```

### Key Files

- Root app: [`gitops/templates/root-prod-app.yaml`](../gitops/templates/root-prod-app.yaml)
- Platform apps: [`gitops/templates/platform/`](../gitops/templates/platform/)
  - `-1-ts-operator.yaml`, `-1-cert-manager.yaml`, `-1-longhorn.yaml`
  - `00-external-secrets.yaml`, `00-velero.yaml`
  - `01-vault.yaml`, `02-seaweedfs.yaml`, `02-valkey.yaml`, `03-monitoring.yaml`, `03-trivy-operator.yaml`, `04-cloudnative-pg.yaml`
- User apps: [`gitops/templates/apps/`](../gitops/templates/apps/) — `03-homepage.yaml`, `05-immich.yaml`, `06-nextcloud.yaml`
- Helm chart: [`gitops/Chart.yaml`](../gitops/Chart.yaml)
- Configuration: [`gitops/values.yaml`](../gitops/values.yaml) (prod) and [`gitops/values-dev.yaml`](../gitops/values-dev.yaml) (dev)
- ADR: [ADR-006: App Health and Vault Ordering](./adrs/006-app-health-and-vault-ordering.md)

---

## 📊 Observability: Prometheus + Grafana + Loki + Alloy

### What's Implemented

**Complete observability stack:**
- **Prometheus** — Metrics collection and storage (time-series database)
- **Grafana** — Dashboard and visualization engine
- **Loki** — Log aggregation (logs as a dimension, not indexed text) — SingleBinary with S3 (SeaweedFS) backend and gateway (`monitoring-loki-gateway`)
- **Grafana Alloy** — Stateless DaemonSet log collector (`discovery.kubernetes` → `loki.source.kubernetes` → `loki.write` to `http://monitoring-loki-gateway.monitoring.svc.cluster.local/loki/api/v1/push` with `X-Scope-OrgID: fake`). No PVC (WAL disabled, ephemeral `/tmp/alloy`), RBAC auto-created by the alloy chart, **replaces Promtail (deprecated)**
- **Integration** — Vault metrics, ArgoCD health, Longhorn status; Loki datasource in Grafana with `X-Scope-OrgID` header
- **Secure Ingress** — All dashboards behind Tailscale zero-trust (single-host gateway)

### Why This Matters

Observability is non-negotiable in production:
- **Debugging** — Know what's happening in the cluster at any moment
- **Alerting** — Detect issues before users notice
- **Trending** — Understand system behavior over time
- **Compliance** — Audit trail for security reviews

### How It Works

1. **Metrics Collection** — Prometheus scrapes endpoints (Vault, ArgoCD, kubelet, etc.)
2. **Time-Series Storage** — Prometheus stores metrics with timestamps
3. **Queries** — Grafana queries Prometheus via PromQL (Prometheus Query Language)
4. **Dashboards** — Pre-built dashboards show:
   - Cluster health (CPU, memory, disk)
   - Vault status (sealed/unsealed, replication, lease count)
   - ArgoCD app sync status and drift
   - Longhorn replication and volume usage
5. **Logs** — Alloy (DaemonSet) discovers pods via Kubernetes API (`discovery.kubernetes` role `pod`), tails logs via `loki.source.kubernetes`, and pushes to Loki via `loki.write` (`/loki/api/v1/push` with `X-Scope-OrgID: fake`). Loki (SingleBinary, S3/SeaweedFS) stores chunks via gateway. No host `varlog` mounts — Alloy uses the API, not the filesystem.
6. **Explore & LogQL** — Grafana Explore queries Loki via LogQL; dashboard Logs panels correlate metrics and logs for the same workload

### Example Dashboard

Grafana dashboard accessible at: `https://grafana.lonk-mirfak.ts.net/` (via Tailscale per-app Ingress)

Includes:
- Vault: Sealed state, rekey progress, auth method usage
- ArgoCD: App health, sync time, missed syncs
- Kubernetes: Node CPU/memory, pod count, error rates
- Longhorn: Replica count, rebuild progress, volume usage
- **Logs (Loki + Alloy):** Explore with LogQL (`{namespace="vault"}` etc.), dashboard Logs panels backed by Alloy-shipped pod logs stored in SeaweedFS S3

> Alloy is stateless — no PVC, no WAL. RBAC (`ServiceAccount` + `ClusterRole`/`ClusterRoleBinding` for pods/nodes discovery) is created automatically by the `alloy` chart (`rbac.create=true`). It replaces Promtail by design decision.

### Key Files

- Chart: [`platform/monitoring/Chart.yaml`](../platform/monitoring/Chart.yaml) — dependencies: `loki:7.3.0`, `kube-prometheus-stack:88.6.1`, `alloy:1.12.1`
- Values: [`platform/monitoring/values.yaml`](../platform/monitoring/values.yaml) — Loki SingleBinary + S3 (SeaweedFS), Grafana Loki datasource (`X-Scope-OrgID: fake`), Alloy `discovery.kubernetes`/`loki.source.kubernetes`/`loki.write` pipeline
- Templates: [`platform/monitoring/templates/`](../platform/monitoring/templates/)
  - Prometheus config: `prometheus-configmap.yaml`
  - Grafana datasources: `grafana-datasources.yaml`
  - Loki S3 config: `loki-config.yaml`
- Application: [`gitops/templates/apps/03-monitoring.yaml`](../gitops/templates/apps/03-monitoring.yaml)
- Log collector: Alloy DaemonSet (stateless, no PVC, RBAC auto-created; replaces Promtail — deprecated) — see `platform/monitoring/values.yaml` `alloy:` block

---

## 💾 Storage: Longhorn + SeaweedFS

### Longhorn: Distributed Block Storage

**What it is:** Kubernetes-native distributed storage that turns local disks on worker nodes into a shared storage pool.

**Why it matters:**
- Stateful workloads (databases, Vault) need persistent storage
- Longhorn provides HA — data replicated across nodes
- CSI integration — applications claim storage via PVCs

**How it works:**
1. **Node Preparation** — Every node must provide `iscsi-tools` and a kubelet mount for `/var/lib/longhorn`
2. **Disk Assignment** — Each node has a `longhorn-disk` directory
3. **Replication** — Longhorn creates replicas across nodes (default 3)
4. **PVC Binding** — Applications claim storage via `PersistentVolumeClaim`
5. **Wave-0 Deployment** — Longhorn deployed before Vault to ensure storage is ready

**CSI Readiness Gate:**
```yaml
# Longhorn's CSI readiness gate ensures PVCs bind before pod starts
podSpec:
  containers: [...]
  volumeClaimTemplates:
    - name: data
      spec:
        storageClassName: longhorn
```

### SeaweedFS: S3-Compatible Object Storage

**What it is:** Distributed object storage (like AWS S3) that runs in the cluster.

**Why it matters:**
- Log aggregation backend (Loki stores logs in S3)
- Backup destination (Velero, future feature)
- Application object storage (photos, documents, etc.)
- S3 API compatibility — works with any S3 client library

**How it works:**
1. **Deployment** — SeaweedFS runs as StatefulSet with Longhorn PVCs
2. **S3 API** — Exposes S3-compatible endpoint inside cluster (`seaweedfs:8333`)
3. **Credentials** — Vault stores S3 access keys, External Secrets syncs to K8s
4. **Applications** — Use standard S3 client (boto3, AWS SDK) with cluster endpoint

### Integration: Loki + SeaweedFS

```yaml
# Loki writes logs to SeaweedFS S3 backend
loki:
  config:
    storage_config:
      s3:
        endpoint: seaweedfs:8333
        s3forcepathstyle: true
        insecure: true
        access_key_id: ${SEAWEEDFS_ACCESS_KEY}
        secret_access_key: ${SEAWEEDFS_SECRET_KEY}
```

### Key Files

- Longhorn deployment: [`gitops/templates/platform/-1-longhorn.yaml`](../gitops/templates/platform/-1-longhorn.yaml) (wave -1, CSI-gated)
- SeaweedFS chart: [`platform/seaweedfs/`](../platform/seaweedfs/)
  - Configuration: [`platform/seaweedfs/values.yaml`](../platform/seaweedfs/values.yaml)
  - S3 credentials management: Vault integration via External Secrets
- ADR: [ADR-005: Longhorn Back to GitOps](./adrs/005-longhorn-back-to-gitops.md)

---

## 🔄 Bootstrap & Idempotency

### The Bootstrap Script

**Location:** [`bootstrap/init-gitops.sh`](../bootstrap/init-gitops.sh)

**What it does:**

1. **Validates prerequisites** — Cluster running, ArgoCD installed, kubeconfig accessible
2. **Deploys root App-of-Apps** — Single `kubectl apply` of the root ArgoCD application
3. **Configures Vault** — Initializes Vault, generates unseal keys, sets up auth methods
4. **Waits for readiness** — Checks that cert-manager and external-secrets are healthy before proceeding
5. **Status report** — Shows which apps are deploying and health status

**Idempotency:**
- Running twice is safe — script checks if root app already exists, skips if deployed
- `--force` flag reapplies even if already deployed
- Status verifier — second run acts as a health check

### Usage

```bash
# Deploy to prod
./bootstrap/init-gitops.sh prod

# Deploy to dev
./bootstrap/init-gitops.sh dev

# Force reapply (safe, idempotent)
./bootstrap/init-gitops.sh prod --force

# Dry-run (preview without applying)
./bootstrap/init-gitops.sh prod --dry-run
```

### Key Concepts

- **Dry-run safety** — Preview changes before applying
- **State verification** — Check cluster state without modifying
- **Incremental deployment** — Rerun to continue partial deployments
- **Error handling** — Clear error messages guide troubleshooting

### Key Files

- Bootstrap script: [`bootstrap/init-gitops.sh`](../bootstrap/init-gitops.sh)
- Root app definition: [`gitops/templates/root-prod-app.yaml`](../gitops/templates/root-prod-app.yaml)
- Vault init logic: Inside bootstrap script (search for `vault_init`)
- Documentation: [`docs/getting-started.md`](./getting-started.md)

---

## 📈 Multi-Environment Configuration

### Environment Strategy

**Two environments, one codebase:**
- **Production** (`values.yaml`) — 3-node Vault, 3-replica Longhorn, monitoring
- **Development** (`values-dev.yaml`) — Single-node Vault (acceptable for dev), local-path storage option

### How It Works

1. **Base Values** — `gitops/values.yaml` defines prod defaults
2. **Dev Overrides** — `gitops/values-dev.yaml` overrides for lighter footprint
3. **Branch Strategy** — Deploy from `main` (prod) or `dev` (development)
4. **Helm Templating** — Single `Chart.yaml` renders differently based on values

### Example: Vault Replicas

```yaml
# values.yaml (prod)
vault:
  replicas: 3

# values-dev.yaml (dev override)
vault:
  replicas: 1
```

### Key Concept

This is **GitOps done right** — no imperative commands like `kubectl set replicas`. All configuration is version-controlled, reviewable, auditable.

---

## ✅ Validation & Quality Gates

### CI/CD Checks

Every commit runs through:

1. **YAML Lint** — Syntax validation for Kubernetes manifests
2. **Helm Lint** — Validation for Helm chart structure
3. **Helm Template** — Verify templates render without errors
4. **Values Validation** — Check that values.yaml and values-dev.yaml are valid
5. **Dry-Run** — Run `helm template` to verify manifest generation

### Local Validation

Before pushing, run locally:

```bash
# Lint all files
just lint

# Validate Helm charts (no cluster required)
just validate

# Format check
just fmt
```

### GitHub Actions

- **Trigger** — On every push to `main` or `dev`
- **Matrix** — Runs against prod and dev values simultaneously
- **Approval gate** — Manual approval required before deploy to prod
- **Rollback** — Revert commit to rollback

### Key Files

- Workflows: [`.github/workflows/`](../.github/workflows/)
  - Validate: `validate.yml`
  - Deploy: `deploy.yml`
- Local mirror: [`justfile`](../justfile) — `just validate` command
- Documentation: [`docs/ci-cd.md`](../docs/ci-cd.md)

---

## 🔗 Integration Points

**This repo assumes a cluster that provides:**
- A running Kubernetes cluster
- ArgoCD already installed
- Longhorn node prerequisites satisfied (`iscsi-tools`, kubelet mounts)

This repository declares everything that runs on the cluster. It allows:
- Cluster upgrades without app redeployment
- Team division — infrastructure team vs. platform/apps team
- Reusability — apply the same GitOps layer to any Kubernetes cluster

---

**Next:** Read the [Roadmap](./roadmap.md) to understand where this is heading, or dive into specific [ADRs](./adrs/) for deep architectural decisions.
