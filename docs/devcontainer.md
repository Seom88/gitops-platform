# Devcontainer — Isolated AI Agent Environment

A Podman devcontainer for running AI coding agents (opencode, gentle-ai) against this repository with a deliberately restricted view of the world. Design rationale: [ADR-025](adrs/025-devcontainer-ai-agents.md).

## Security model

| Asset | Access from inside the container |
|---|---|
| Repository files | Read/write (workspace bind) |
| `.env`, repo-root `kubeconfig` | **Masked** with `/dev/null` binds — unreadable |
| SOPS age keys, admin `k3s.yaml` | Never mounted |
| Host `~/.ssh` | Only `~/.ssh/id_ed25519` is mounted, read-only — no other key, agent or config |
| Docker/podman socket | Never mounted |
| Tailscale | Not installed — network rides the host client via NAT |
| Cluster | **Read-only** via dedicated SA `dev-agents`: resources get/list/watch + pod logs, **no Secrets, no ConfigMaps, no exec/attach/portforward, no writes**; token expires (~24h) |
| `pi.env` (container environment) | **Readable from inside the container** — never place cluster credentials there |
| Internet | Yes (pnpm, agents) |

The host `~/.kube/config` is never mounted. The container sees only the kubeconfig minted by `./scripts/dev-kubeconfig.sh`, mounted read-only at `/home/vscode/.kube/config`.

`runArgs` passes `.devcontainer/pi.env` with `--env-file`. Any value in that file is readable from inside the container — through `podman inspect` on the host and through `/proc/*/environ` in the container — so it must hold only agent API keys and the git identity, never cluster credentials.

SSH exposure is narrow: only `${localEnv:HOME}/.ssh/id_ed25519` is mounted, read-only at `/home/vscode/.ssh/id_ed25519`. A writable `known_hosts` and generated `ssh_config` live on the `gitops-ssh-known-hosts` volume, and `git config --global core.sshcommand` points at that config. Set `GIT_SSH_KEY` to override key selection; the selected key is validated with `ssh-keygen -y`.

## Prerequisites (host)

- `podman` (rootless works — the container runs non-root as `vscode`, uid 1000, with `updateRemoteUserUID: false`)
- The `devcontainer` CLI and `just`
- `kubectl` with an admin context (your k3s admin kubeconfig)
- `~/.ssh/id_ed25519` present (git over SSH uses only this key)
- RBAC applied: the branch's `platform/ts-operator/templates/users/dev-agents*` files synced by ArgoCD (verify: `kubectl get sa dev-agents -n tailscale`)

## First use

```bash
# 1. Provision the dedicated, expiring kubeconfig (host, outside the repo)
./scripts/dev-kubeconfig.sh

# 2. Start the devcontainer
just dev-up   # or ./.devcontainer/scripts/up.sh
```

`devcontainer.json` mounts the freshly minted kubeconfig — `${localEnv:HOME}/.kube/devcontainer/kubeconfig` on the host (overridable with `DEVCONTAINER_KUBECONFIG_DIR`) — read-only at `/home/vscode/.kube/config`.

`up.sh` is a thin wrapper around `devcontainer up`. Before starting it:

- injects the host Wayland socket only when it exists (detected by globbing `/run/user/$uid/wayland-*`), because a bind to a missing socket aborts `up` and mounts in `devcontainer.json` cannot be conditional;
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

The SA token expires (`DEVCONTAINER_TOKEN_DURATION`, default 24h). Rerun `./scripts/dev-kubeconfig.sh`, then restart the container (configs are read at start).

## Verifying the agent's view

Inside the container:

```bash
kubectl auth can-i --list          # should show get/list/watch only, no secrets
kubectl get pods -A                # works
kubectl logs -n kube-system <pod>  # works
kubectl get secrets -A             # Forbidden (RBAC)
kubectl delete pod <x>             # Forbidden
```

## Troubleshooting

- **Container fails to start**: the minted kubeconfig (`${localEnv:HOME}/.kube/devcontainer/kubeconfig`) is missing — run `./scripts/dev-kubeconfig.sh` first.
- **`error: serviceaccounts "dev-agents" not found`** in the provisioning script: the ArgoCD ts-operator Application has not synced the new RBAC yet — wait for the sync, or run `just sync`.
- **Token expired errors (401)**: rerun `./scripts/dev-kubeconfig.sh`, then restart the container.
- **Git over SSH fails**: `~/.ssh/id_ed25519` is absent, so git falls back to the default identity and authentication fails — place the key on the host and restart the container.
- **Wayland clipboard does not work**: start with `just dev-up` or `./.devcontainer/scripts/up.sh`; plain `devcontainer up` adds no display mount, and on X11 or headless the clipboard is intentionally absent.
- **`pi.env` missing**: `scripts/pi-env-init.sh` (run by `initializeCommand` and `up.sh`) copies `.devcontainer/pi.env.example` to it on first run; fill in the keys and restart.
