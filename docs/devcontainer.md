# Devcontainer — Isolated AI Agent Environment

A Podman devcontainer for running AI coding agents (opencode, gentle-ai) against this repository with a deliberately restricted view of the world. Design rationale: [ADR-025](adrs/025-devcontainer-ai-agents.md).

## Security model

| Asset | Access from inside the container |
|---|---|
| Repository files | Read/write (workspace bind) |
| `.env`, repo-root `kubeconfig` | **Masked** with `/dev/null` binds — unreadable |
| SOPS age keys, admin `k3s.yaml` | Never mounted |
| Docker/podman socket | Never mounted |
| Tailscale | Not installed — network rides the host client via NAT |
| Cluster | **Read-only** via dedicated SA `dev-agents`: resources get/list/watch + pod logs, **no Secrets, no ConfigMaps, no exec/attach/portforward, no writes** |
| Internet | Yes (pnpm, agents) |

## Prerequisites (host)

- `podman` (rootless works — the container runs non-root as `agent`, uid 1000)
- `kubectl` with an admin context (your k3s admin kubeconfig)
- RBAC applied: the branch's `platform/ts-operator/templates/users/dev-agents*` files synced by ArgoCD (verify: `kubectl get sa dev-agents -n tailscale`)

## First use

```bash
# 1. Provision the dedicated, expiring kubeconfig (host, outside the repo)
./scripts/dev-kubeconfig.sh

# 2. Start the devcontainer
devcontainer up --workspace-folder .   # or open in VS Code / VSCodium with podman as engine
```

`devcontainer.json` mounts the freshly minted `~/.config/devcontainer/kubeconfig` read-only at `/home/agent/.kube/config`.

## Refreshing the credential

The SA token expires (`DEVCONTAINER_TOKEN_DURATION`, default 24h). Rerun `./scripts/dev-kubeconfig.sh`, then restart the container (configs are read at start).

## Verifying the agent's view

Inside the container:

```bash
kubectl auth can-i --list          # should show get/list/watch only, no secrets
kubectl get pods -A                # works
kubectl get secrets -A             # Forbidden (RBAC)
kubectl logs -n kube-system <pod>  # works
kubectl delete pod <x>             # Forbidden
```

## Troubleshooting

- **Container fails to start**: `~/.config/devcontainer/kubeconfig` does not exist — run `./scripts/dev-kubeconfig.sh` first.
- **`error: serviceaccounts "dev-agents" not found`** in the provisioning script: the ArgoCD ts-operator Application has not synced the new RBAC yet — wait for the sync, or run `just sync`.
- **Token expired errors (401)**: rerun `./scripts/dev-kubeconfig.sh`, restart container.
- **Cannot reach `https://100.64.0.12:6443`**: the host tailscale client must be up (the container depends on host routing).
