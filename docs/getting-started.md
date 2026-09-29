# Getting Started

This guide provides the steps to initialize the Homelab GitOps environment, including the setup of HashiCorp Vault for secret management. **ArgoCD is NOT installed here** — it is a cluster prerequisite. **Longhorn** is deployed by this repo itself as a wave -1 platform app with a CSI readiness gate, so no storage needs to be pre-installed.

## Prerequisites

- A running Kubernetes cluster with **ArgoCD** already installed.
- `kubectl` configured to point to your cluster.
- `helm` installed locally.
- `jq` installed locally.
- [`just`](https://github.com/casey/just) installed locally (command runner — all common operations are available as recipes).

## 1. Bootstrap the Environment

Run the initialization script to configure the foundation of your GitOps flow. The script deploys the root **App-of-Apps** (cert-manager, External Secrets Operator and the platform apps sync via ArgoCD) and configures **Vault**. You can choose between `prod` (default) and `dev` environments using the `just` recipes:

```bash
# For production (default)
just init-prod

# For development
just init-dev
```

> [!TIP]
> The raw scripts are also available at `./bootstrap/01-init-gitops.sh [prod|dev]` if you prefer running them directly.

> [!IMPORTANT]
> The cluster must have **ArgoCD** installed **before** running the bootstrap. Longhorn is deployed by this repo as a wave -1 App-of-Apps app with a CSI readiness gate — the bootstrap script does not install ArgoCD or any storage component.

> [!NOTE]
> **Wave ordering and idempotency:** Platform apps are plain `Application` resources in `gitops/templates/apps/` ordered by `argocd.argoproj.io/sync-wave`: `00` cert-manager/external-secrets/longhorn (wave 0) → `01` vault (wave 1) → `02` seaweedfs (wave 2) → `03` monitoring (wave 3, `sync-only`) → `04` tailscale (wave 4, `sync-only`, always last). The default `wave-policy: healthy` makes each wave wait for `Synced + Healthy` (custom Application health Lua, ADR-006), matching Flux `dependsOn` semantics; `sync-only` leaves need only `Synced`. Bootstrap is idempotent — if the root `Application` already exists the script skips reapply and acts as a status verifier. Because `monitoring` and `tailscale` are `sync-only` leaves, Tailscale still exposes other apps even if monitoring is degraded.

## 2. Configure Vault

The bootstrap script automatically initializes Vault and configures the necessary secrets engines.

### Access Vault UI

1. **Get the root token**:
   The script prints the root token at the end, but you can always retrieve it with a `just` recipe:
   ```bash
   just vault-token
   ```
   > [!NOTE]
   > This automatically finds the Vault unseal secret regardless of environment (prod/dev). The underlying command is `kubectl -n vault get secret <name> -o jsonpath="{.data.root-token}" | base64 -d`.
2. **Start port-forwarding**:
   ```bash
   just pf-vault
   ```
3. **Login**: Go to [https://localhost:8200](https://localhost:8200) and use the token from step 1.

> [!TIP]
> Once inside, follow the [Secret Structure guide](secrets-structure.md) to organize your secrets correctly. The automation already sets up the `secret/` KV engine.

## 3. Access ArgoCD

ArgoCD manages all the services in your cluster. Once Vault is configured, the Tailscale operator will automatically expose your services if configured.

### Local Access (Verification)

To check the sync status of your applications:

| Action | Command |
| :--- | :--- |
| **Get Password** | `just argocd-password` |
| **Port Forward** | `just pf-argocd` |

Access the UI at [localhost:8080](http://localhost:8080) with user `admin`.

## 4. Connectivity via Tailscale

> **Prerequisite:** Cilium CNI 1.20.1 must be installed and Ready (`kubeProxyReplacement: strict`) before this repo's `CiliumNetworkPolicy` rules are enforced. Verify before bootstrapping:
> ```bash
> kubectl -n kube-system get pods -l k8s-app=cilium
> cilium status
> kubectl get ciliumnetworkpolicies -A
> ```

If you have the Tailscale operator configured, your services will be reachable through your Tailnet.

- Verify Tailscale nodes are created in your admin console.
- Access services via per-app devices on the tailnet — one `Ingress` + MagicDNS hostname per app, each served at `/` root (see [ADR-018](adrs/018-per-app-tailscale-ingress.md) and [Networking](./networking.md)):
  ```bash
  open https://grafana.lonk-mirfak.ts.net/
  open https://argocd.lonk-mirfak.ts.net/
  open https://longhorn.lonk-mirfak.ts.net/
  open https://vault.lonk-mirfak.ts.net/
  ```
   Per-app hostnames are used (`argocd`, `grafana`, `prometheus`, `longhorn`, `seaweedfs-s3`, `seaweedfs-admin`, `homepage`, `hubble`, `vault` on `*.lonk-mirfak.ts.net`; `-dev` suffix in dev). There is no shared gateway device.

## Pre-commit (fast local checks)

This repo ships a `.pre-commit-config.yaml` with fast local checks. Enable it once with `pre-commit install` (after `pip install pre-commit`):

- `detect-secrets` (gated by `.secrets.baseline`) — blocks commits introducing new potential secrets; CI re-checks every push via the `Secret scan` step in the `ci.yaml` validate job. If the hook flags a false positive, mark it inline with `# pragma: allowlist secret`, or — for a genuinely safe pattern — run `detect-secrets audit .secrets.baseline` to record the verdict; never hand-edit or auto-regenerate the baseline to make CI pass.
- `inline-image-convention` (local hook) — fails fast on split `repository:` + `tag:` blocks in staged `values*.yaml`; use inline `image: "repo:tag@sha256:…"` so Renovate Manager 1 keeps tracking the ref. Same check runs in CI as `just validate-images`.
- `check-yaml` / `check-json` (`pre-commit-hooks`) — syntax check staged YAML/JSON files, replacing the old custom sanity loops.
- `yamllint` (`-c .yamllint.yaml`) — style lint for staged YAML.
- `shellcheck` (binary download, no system dependency) — lint staged shell scripts.

Helm templates (`(platform|apps|gitops)/*/templates/`, `platform/longhorn/charts/`) are excluded from `check-yaml`/`yamllint` — they contain Go sprig (`{{ }}`), which is not valid YAML; `helm lint` owns them. Hook revs are bumped automatically by Renovate's `pre-commit` manager.
