# Devcontainer — Isolated AI Agent Environment

A Podman devcontainer for running AI coding agents (opencode, gentle-ai) against this repository with a deliberately restricted view of the world. Design rationale: [ADR-025](adrs/025-devcontainer-ai-agents.md).

## Security model

| Asset | Access from inside the container |
|---|---|
| Repository files | Read/write (workspace bind) |
| `.env`, repo-root `kubeconfig` | **Masked** with `/dev/null` binds — unreadable |
| SOPS age keys, prod admin `k3s.yaml` | Never mounted |
| Host `~/.ssh` | Only `~/.ssh/id_ed25519` is mounted, read-only — no other key, agent or config |
| Docker/podman socket | Never mounted |
| Tailscale | Not installed — network rides the host client via NAT |
| Cluster (prod) | **Read-only** via dedicated SA `dev-agents`: resources get/list/watch + pod logs, **no Secrets, no ConfigMaps, no exec/attach/portforward, no writes**; token expires (~24h) |
| Cluster (dev) | **Full access** via a staged copy of `DEVCONTAINER_DEV_KUBECONFIG`. This credential can write to the dev cluster; it is never used for prod. |
| `.env` (container environment) | **Readable from inside the container** — never place cluster credentials there |
| Internet | Yes (pnpm, agents) |

The host prod admin kubeconfig is never mounted directly. `devcontainer.json` runs `.devcontainer/scripts/dev-kubeconfig.sh` as `initializeCommand` on the host before the container is created (and on subsequent starts). The script stages:

- `$HOME/.kube/devcontainer/prod/kubeconfig` — read-only SA `dev-agents` with a bounded token;
- `$HOME/.kube/devcontainer/dev/kubeconfig` — a copy of `DEVCONTAINER_DEV_KUBECONFIG`, full access to the dev cluster.

`devcontainer.json` mounts the two staging subdirectories read-only at `/home/vscode/.kubeconfigs/{prod,dev}`, and `KUBECONFIG` lists both files. Missing env vars/files only warn: the container still starts and kubectl ignores the missing entry. The script refuses to use the prod admin kubeconfig as the dev source and refuses paths inside the repo. Because `initializeCommand` runs before creation, the staging subdirectories exist when the mounts are applied.

The staged prod kubeconfig must use the **direct API server**, not the Tailscale operator proxy. The proxy (`*.ts.net`) authenticates with your Tailscale identity (`tailnet-admins` → cluster-admin) and ignores the ServiceAccount token, so staging the proxy URL would silently give the agent admin access. If the admin kubeconfig points at a `*.ts.net` proxy, the script resolves the control-plane node, gets its Tailscale IP with `tailscale ip -4`, stages `https://<ip>:6443`, and embeds the cluster CA from `kube-root-ca.crt`. Set `DEVCONTAINER_API_SERVER` to override the URL; `*.ts.net` values are refused.

The dev kubeconfig must contain only dev-cluster credentials (do not point it at a file that also carries prod admin contexts) and should be self-contained (embedded certificate data), because it is copied into the container as-is.

`runArgs` passes the repo-root `.env` with `--env-file`. Any value in that file is readable from inside the container — through `podman inspect` on the host and through `/proc/*/environ` in the container — so it must hold only agent API keys and the git identity, never cluster credentials.

SSH exposure is narrow: only `${localEnv:HOME}/.ssh/id_ed25519` is mounted, read-only at `/home/vscode/.ssh/id_ed25519`. A writable `known_hosts` and generated `ssh_config` live on the `gitops-ssh-known-hosts` volume, and `git config --global core.sshcommand` points at that config. Set `GIT_SSH_KEY` to override key selection; the selected key is validated with `ssh-keygen -y`.

## Prerequisites (host)

- `podman` (rootless works — the container runs non-root as `vscode`, uid 1000, with `updateRemoteUserUID: false`)
- The `devcontainer` CLI and `just`
- `kubectl` with a prod admin context, or `DEVCONTAINER_PROD_ADMIN_KUBECONFIG` pointing at the prod admin kubeconfig (outside the repo)
- The prod admin kubeconfig must trust the API server TLS: embedded `certificate-authority-data`, a readable `certificate-authority` file, or a certificate signed by a public CA in the system trust store. `insecure-skip-tls-verify` is refused.
- `tailscale` CLI on the host (optional): used to auto-detect the control-plane Tailscale IP when the admin kubeconfig uses the API server proxy. Otherwise set `DEVCONTAINER_API_SERVER` explicitly.
- Optional dev cluster kubeconfig at `DEVCONTAINER_DEV_KUBECONFIG` (full access)
- `~/.ssh/id_ed25519` present (git over SSH uses only this key)
- RBAC applied in prod: the branch's `platform/ts-operator/templates/users/dev-agents*` files synced by ArgoCD (verify: `kubectl get sa dev-agents -n tailscale`)

Configure the source paths in `.env` (see `.env.example`); the staged copies are created automatically:

```bash
DEVCONTAINER_PROD_ADMIN_KUBECONFIG=$HOME/.kube/prod-admin.yaml
# Optional; auto-detected when the admin kubeconfig uses the Tailscale proxy:
# DEVCONTAINER_API_SERVER=https://<control-plane-tailscale-ip>:6443
DEVCONTAINER_DEV_KUBECONFIG=$HOME/.kube/dev.yaml
```

## First use

No manual kubeconfig step is required: `initializeCommand` prepares both credentials before the container is created.

```bash
just dev-up   # or ./.devcontainer/scripts/up.sh
```

To prepare/refresh the credentials without starting the container:

```bash
just dev-kubeconfig   # or ./.devcontainer/scripts/dev-kubeconfig.sh
```

`up.sh` only ensures the staging subdirectories exist; the static mounts are declared in `devcontainer.json`. If you used the old single-file setup, `$HOME/.kube/devcontainer/kubeconfig` is no longer mounted and can be deleted.

`up.sh` is a thin wrapper around `devcontainer up`. Before starting it:

- injects the host Wayland socket only when it exists (detected by globbing `/run/user/$uid/wayland-*`), because a bind to a missing socket aborts `up` and mounts in `devcontainer.json` cannot be conditional;
- ensures `$HOME/.kube/devcontainer/{prod,dev}` exist, since both are bind-mounted by `devcontainer.json`;
- forwards extra arguments, e.g. `./.devcontainer/scripts/up.sh --remove-existing-container`.

On X11, TTY or SSH sessions no Wayland socket is mounted, so the container starts without clipboard support; `up.sh` reports the detected session on stderr.

Everyday recipes:

- `just dev-recreate` — rebuild and recreate after changing `devcontainer.json` or the `Dockerfile` (named volumes survive)
- `just dev-shell` — interactive fish shell as the container user
- `just dev-status` — container state
- `just dev-down` — stop the container, keeping it and its volumes
- `just dev-clean` — remove the container, keeping the volumes
- `just dev-doctor` — check host prerequisites and display-socket detection
- `just dev-build` — build the image without starting the container
- `just dev-kubeconfig` — prepare/refresh both kubeconfigs manually

## Toolchain

The image builds from the `.devcontainer/` context only (`.devcontainer/Dockerfile`, `.dockerignore`), on `mcr.microsoft.com/devcontainers/base:debian13` pinned by digest. It ships:

- git, curl, kubectl `v1.37.1`, helm `v3.22.1`, velero `v1.18.4`, k9s `v0.51.0`
- Node.js `24.22.0` via fnm and pnpm `12.15.0`
- python3 with uv and a virtualenv at `/opt/venv`
- shellcheck, jq/yq, ripgrep
- fish and starship (gruvbox-rainbow preset)
- engram prebuilt at `/home/vscode/.local/bin/engram`

Deliberately absent: the Tailscale client, any container-engine socket, a host Go toolchain, trivy, and `just` (a host-side convenience only).

## Shell and prompt

`fish` is the `vscode` user's default shell and starship is loaded through `~/.config/fish/conf.d/starship.fish`; no config file needs editing.

The prompt shows a project badge driven by `PROJECT_NAME` (set to `gitops-platform` in `devcontainer.json`) instead of the generic container username, so several devcontainers are easy to tell apart. Change `PROJECT_NAME` per project when copying this setup.

## Refreshing the credential

`initializeCommand` runs the preparation script on every container start, so the prod SA token (`DEVCONTAINER_TOKEN_DURATION`, default 24h) and the dev copy are refreshed automatically. To refresh a running container without restarting, run `just dev-kubeconfig`; the read-only bind mount exposes the new files immediately. Rotate the dev cluster credential the same way you normally rotate it, then rerun the script or restart the container.

## Verifying the agent's view

Inside the container:

```bash
kubectl config get-contexts       # prod-readonly plus the dev context when mounted
kubectl auth can-i --list         # prod: get/list/watch only, no secrets
kubectl get pods -A               # prod read works
kubectl logs -n kube-system <pod> # prod logs work
kubectl get secrets -A            # prod: Forbidden (RBAC)
kubectl delete pod <x>            # prod: Forbidden
```

Both kubeconfigs are mounted read-only, so `kubectl config use-context` cannot persist a switch. Use the dev context explicitly: `kubectl --context <dev-context> ...` or `KUBECONFIG=/home/vscode/.kubeconfigs/dev/kubeconfig kubectl ...`.

## Troubleshooting

- **`initializeCommand` fails with "must not be inside the staging directory" or "inside the repo tree"**: move `DEVCONTAINER_PROD_ADMIN_KUBECONFIG` outside the repo and the staging directory, update `.env`, then retry. The container is not created until the security check passes.
- **`kubectl` has no context**: check the `initializeCommand` warnings (run `just dev-kubeconfig` to see them again), make sure `DEVCONTAINER_PROD_ADMIN_KUBECONFIG` and/or `DEVCONTAINER_DEV_KUBECONFIG` point at existing files outside the repo, then restart the container. Unset/missing files are skipped by design.
- **`auth whoami` shows your Tailscale user instead of `dev-agents`**: the staged prod kubeconfig is pointing at the Tailscale API server proxy. Set `DEVCONTAINER_API_SERVER` to the direct control-plane Tailscale IP (or install `tailscale` on the host so the script can auto-detect it), rerun `just dev-kubeconfig`, and restart the container.
- **`insecure-skip-tls-verify` or `Certificate authority file not found`**: the prod admin kubeconfig's TLS settings are unusable for staging. Point it at a readable `certificate-authority` file, embed `certificate-authority-data`, or use a publicly trusted certificate; `insecure-skip-tls-verify` is refused on purpose.
- **`error: serviceaccounts "dev-agents" not found`** in the preparation script: the prod ArgoCD ts-operator Application has not synced the new RBAC yet — wait for the sync, or run `just sync`.
- **Token expired errors (401) on prod**: run `just dev-kubeconfig`; the running container picks up the new file through the bind mount.
- **Git over SSH fails**: `~/.ssh/id_ed25519` is absent, so git falls back to the default identity and authentication fails — place the key on the host and restart the container.
- **Wayland clipboard does not work**: start with `just dev-up` or `./.devcontainer/scripts/up.sh`; plain `devcontainer up` adds no display mount, and on X11 or headless the clipboard is intentionally absent.
- **`.env` missing**: `devcontainer up` passes it with `--env-file` and fails if absent. Run `just secrets-init` (or copy `.env.example` to `.env`) and fill in the values.
