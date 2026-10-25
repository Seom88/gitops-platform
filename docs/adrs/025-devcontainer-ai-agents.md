# ADR-025: Podman Devcontainer for AI Agents — Debian Slim, pnpm, Least-Privilege SA RBAC

**Status:** Accepted · **Date:** 2026-10-18 · **Deciders:** Seom88 · **Related:** [ADR-010](010-tailscale-oauth-ci-generated.md) (CI OAuth secrets), [ADR-011](011-tailscale-dns-np.md) (operator DNS), [`docs/ci-cd.md`](../ci-cd.md) (kubeconfig paths), [`docs/devcontainer.md`](../devcontainer.md) (usage guide), [`docs/sops.md`](../sops.md) (secret hygiene)

## Context

AI coding agents (opencode + gentle-ai) work inside this repository, and agents attempt to inspect what they should not — in the past an agent reached secret material by decoding SOPS or reading cluster Secrets. The requirement is a development environment that confines agents to the workspace and a deliberately read-only cluster view:

- Isolation from the host (podman, no socket mounts, no privileged mode).
- Debian slim base (user decision after evaluating AlmaLinux).
- Agents installed with pnpm, never npm.
- Cluster access with no tailscale package in the container — the host's tailscale client provides the network path.
- Read-only cluster RBAC (logs yes, secrets no) authored in `platform/ts-operator/templates/users/`.
- Absolutely no inheritance of the human kubeconfig, `.env`, or SOPS age keys.

## Decision

**A digest-pinned `debian:bookworm-slim` Podman devcontainer (non-root `agent` user) talking to the k3s API server directly over the tailnet IP, with agent RBAC carried by a dedicated ServiceAccount — never by a Tailscale identity.**

- **Minimal image tooling** (no helm/trivy/yamllint/shellcheck/just replication of the `scripts/`+`justfile` toolchain): git, kubectl `v1.37.0` (matches the repo's in-cluster pin), Node.js 24 LTS from the official tarball, pnpm via the standalone installer (pinned `PNPM_VERSION`), ripgrep, jq.
- **Agents via pnpm:** `opencode-ai` installs through pnpm global (`--allow-build=opencode-ai` is required — pnpm ≥ 10 blocks lifecycle scripts by default and opencode-ai's postinstall selects the native binary). `npm` is not present in the image.
- **Recorded pnpm exception — gentle-ai:** it is absent from the npm/pnpm registries (404 on `gentle-ai` and `@gentleman-programming/gentle-ai`). It installs from the pinned GitHub release tarball `v4.2.0`, sha256-verified against the release's published `checksums.txt`. Like other digest pins, refreshes are manual.
- **Host confinement:** no docker/podman socket mount, no privileged mode, no host networking; the container's access is the writeable workspace bind plus one read-only file: the agent kubeconfig.
- **Secret masking:** the workspace bind masks `.env` and a repo-root `kubeconfig` with `/dev/null` binds — agents physically cannot read them even though they live in the mounted tree. SOPS age keys (`~/.config/sops/age/keys.txt`, `/tmp/age-keys.txt`) are never mounted.
- **RBAC shape** (`platform/ts-operator/templates/users/`, plain YAML, applied by the ArgoCD ts-operator Application in both prod and dev): ServiceAccount `dev-agents` (namespace `tailscale`), ClusterRole `dev-agents-read` with explicit get/list/watch rules across core/apps/batch/networking.k8s.io/autoscaling/storage.k8s.io/argoproj.io/cilium.io — pods/log and nodes included — and a hard exclusion of Secrets, ConfigMaps (default decision), and all exec/attach/portforward/write verbs; ClusterRoleBinding `dev-agents-read`.
- **Credential sourcing: ServiceAccount, not Tailscale group.** Group subjects only authorize traffic authenticated through the operator API-server proxy (`beth`); the devcontainer reaches `https://100.64.0.12:6443` directly through the host tailscale NAT with plain k8s credentials. Binding a Tailscale group would mean inheriting the human's identity — which is `cluster-admin` via `tailnet-admins` — recreating exactly the incident class this feature exists to prevent.
- **Kubeconfig provisioning:** `scripts/dev-kubeconfig.sh` (host-side, manual) extracts server + CA data from the admin context, mints a bounded token (`kubectl create token dev-agents -n tailscale`, `DEVCONTAINER_TOKEN_DURATION`, default 24h), writes `${localEnv:HOME}/.kube/devcontainer/kubeconfig` (mode 600), never echoes the token, and refuses to write inside the repository.

## Alternatives Considered

| Option | Tradeoff | Verdict |
|---|---|---|
| AlmaLinux base | RHEL-family parity, but the devcontainer Features ecosystem targets Debian/Ubuntu and the surface is larger | Rejected — no RHEL parity requirement; Debian slim is the smallest supported base |
| Reuse the human kubeconfig (`tailnet-admins` → cluster-admin) | Zero provisioning work | Rejected — the agent would hold full admin: argocd-initial-admin-secret, vault unseal keys, writes |
| Operator API proxy (`tailscale configure kubeconfig beth`) inside the container | Identity-fresh RBAC, no stored token | Rejected — needs per-identity client certs and the human's tailnet groups; the direct-IP path already exists (`docs/ci-cd.md`) |
| Allow Secrets/ConfigMaps in the agent role | Simpler debugging | Deferred — Secrets are the adversarial target; ConfigMaps stay excluded by default, one line to re-add |
| Official `mcr.microsoft.com/devcontainers/base` image | Batteries included | Rejected — heavier than needed for a hand-rolled minimal toolchain |

## Consequences

- The RBAC lands cluster-wide on the next ArgoCD sync of the ts-operator chart — review the `templates/users/` diff before merging.
- The SA token is the only credential inside the container and expires (24h default): rerun `scripts/dev-kubeconfig.sh` to refresh.
- gentle-ai upgrades are manual (tarball pin, checksum-verified) until it ships to a registry.
- The container still reaches the internet and the tailnet IP; network ACL refinement is a Tailscale-side concern, out of scope here.

## Amendment 2026-10-25

- The runtime image is now `mcr.microsoft.com/devcontainers/base:debian13`, pinned by digest, with the non-root user `vscode` (uid 1000, `updateRemoteUserUID: false`); the hand-rolled Debian slim image is retired.
- The "Reuse the human kubeconfig" alternative stays rejected. The SA-only kubeconfig mount is restored after a regression, and the host `~/.kube/config` is never mounted.
- helm, k9s, velero and kubectl are now shipped for operator workflows; the earlier "minimal image tooling" decision no longer holds.
- The invariants are unchanged: SA-only kubeconfig, `/dev/null` masking of `.env` and the repo-root `kubeconfig`, no container-engine socket, and no Tailscale client in the container.
