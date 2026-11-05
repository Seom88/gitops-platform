# Getting Started

This guide provides the steps to initialize the Homelab GitOps environment, including the setup of encrypted secrets (SOPS + age — [ADR-017](adrs/017-vault-paused-sops-default.md)). **ArgoCD is NOT installed here** — it is a cluster prerequisite. **Longhorn** is deployed by this repo itself as a wave -1 platform app with a CSI readiness gate, so no storage needs to be pre-installed.

## Prerequisites

- A running Kubernetes cluster with **ArgoCD** already installed.
- `kubectl` configured to point to your cluster.
- `helm` installed locally.
- `jq` installed locally.
- [`just`](https://github.com/casey/just) installed locally (command runner — all common operations are available as recipes).

## 1. Bootstrap the Environment

Run the initialization script to configure the foundation of your GitOps flow. The script deploys the root **App-of-Apps** (cert-manager, the optional External Secrets Operator and the platform apps sync via ArgoCD) and applies the SOPS-encrypted secrets ([SOPS + age](sops.md) is the default secrets path — [ADR-017](adrs/017-vault-paused-sops-default.md); Vault is paused, not deleted). You can choose between `prod` (default) and `dev` environments using the `just` recipes:

```bash
# For production (default)
just init-prod

# For development
just init-dev
```

> [!TIP]
> The raw scripts are also available at `./bootstrap/init-gitops.sh [prod|dev]` if you prefer running them directly. Use `--check` for a read-only verification or `--force` to reapply the root Application.

> [!IMPORTANT]
> The cluster must have **ArgoCD** installed **before** running the bootstrap. Longhorn is deployed by this repo as a wave -1 App-of-Apps app with a CSI readiness gate — the bootstrap script does not install ArgoCD or any storage component.

> [!NOTE]
> **Wave ordering and idempotency:** Platform apps are plain `Application` resources in `gitops/templates/` ordered by `argocd.argoproj.io/sync-wave`: wave `-2` ts-operator → wave `-1` cert-manager/cloudnative-pg/longhorn → wave `0` external-secrets/velero → wave `1` vault (gated off by default, ADR-017) → wave `2` valkey (`healthy`) → wave `3` monitoring/trivy-operator/kepler/homepage (`sync-only`) → wave `5` immich → wave `6` nextcloud (user apps, `sync-only`). The default `wave-policy: healthy` makes each wave wait for `Synced + Healthy` (custom Application health Lua, ADR-006), matching Flux `dependsOn` semantics; `sync-only` leaves need only `Synced`. Bootstrap is idempotent — if the root `Application` already exists the script skips reapply and acts as a status verifier. Because `monitoring` is a `sync-only` leaf, application waves do not wait for it to become healthy.

> [!TIP]
> Working with AI coding agents? [`docs/devcontainer.md`](devcontainer.md) describes an optional Podman devcontainer that mounts masked secrets and a read-only production ServiceAccount (`just dev-up`). Bootstrap works the same from inside it.

## 2. Secrets (SOPS default, Vault paused)

New secrets ship encrypted in git via **SOPS + age** — see the [Getting started with SOPS flow](sops.md): `bootstrap/init-sops.sh` + `just secrets-apply`. Nothing else is required for the default path.

> [!TIP]
> To organize secret structure (for example if you plan to re-enable the Vault path later), follow the [Secret Structure guide](secrets-structure.md).

<details>
<summary>Re-enabling Vault (optional — ADR-017)</summary>

Vault is paused, not deleted: `<chart>/sops/` values and the ArgoCD Applications are gated on `vault.enabled` (`false` in `gitops/values.yaml`). If you flip it back on:

1. **Get the root token**: the script prints it, or:
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

</details>

## 3. Access ArgoCD

ArgoCD manages all the services in your cluster; the Tailscale operator automatically exposes them per app (each chart owns its own Ingress).

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
  open https://nextcloud.lonk-mirfak.ts.net/
  ```
  Per-app hostnames are used (`argocd`, `grafana`, `prometheus`, `longhorn`, `homepage`, `hubble`, `immich`, `nextcloud`, `collabora` on `*.lonk-mirfak.ts.net`; `-dev` suffix in dev). There is no shared gateway device. A `vault` device appears only if you re-enable Vault (ADR-017).

## Pre-commit (fast local checks)

This repo ships a `.pre-commit-config.yaml` with fast local checks. Enable it once with `pre-commit install` (after `pip install pre-commit`):

- `detect-secrets` (gated by `.secrets.baseline`) — blocks commits introducing new potential secrets; CI re-checks every push via the `Secret scan` step in the `ci.yaml` validate job. If the hook flags a false positive, mark it inline with `# pragma: allowlist secret`, or — for a genuinely safe pattern — run `detect-secrets audit .secrets.baseline` to record the verdict; never hand-edit or auto-regenerate the baseline to make CI pass.
- `inline-image-convention` (local hook) — fails fast on split `repository:` + `tag:` blocks in staged `values*.yaml`; use inline `image: "repo:tag@sha256:…"` so Renovate Manager 1 keeps tracking the ref. Same check runs in CI as `just validate-images`.
- `check-yaml` / `check-json` (`pre-commit-hooks`) — syntax check staged YAML/JSON files, replacing the old custom sanity loops.
- `yamllint` (`-c .yamllint.yaml`) — style lint for staged YAML.
- `shellcheck` (binary download, no system dependency) — lint staged shell scripts.

Helm templates (`(platform|apps|gitops)/*/templates/`, `platform/longhorn/charts/`) are excluded from `check-yaml`/`yamllint` — they contain Go sprig (`{{ }}`), which is not valid YAML; `helm lint` owns them. Hook revs are bumped automatically by Renovate's `pre-commit` manager.
