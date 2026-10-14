# Secrets Structure

This document describes the secrets required by applications in this homelab setup.

## Enable Secrets Engine (KV v2)

Before creating secrets, ensure the KV v2 secrets engine is enabled at path `secret`:

![Secret Engines](secrets-steps/secret-engines.png)

1. Go to **Secrets Engines** in Vault UI
2. Enable **KV** at path `secret`
3. Select version 2

## Tailscale OAuth Secret (CI-generated, no Vault)

**Kubernetes Secret:** `tailscale/operator-oauth` (plain `Secret`, **not** `ExternalSecret`)

**Required Keys:**

| Key | Description | Source |
|-----|-------------|--------|
| `client_id` | Tailscale OAuth client ID (`tag:cicd`) | GitHub Secret `TS_OAUTH_CLIENT_ID` / local env `TS_OAUTH_CLIENT_ID` |
| `client_secret` | Tailscale OAuth client secret | GitHub Secret `TS_OAUTH_SECRET` / local env `TS_OAUTH_SECRET` (alias `TS_OAUTH_CLIENT_SECRET` also accepted in bootstrap) |

**How it is created:**

The secret is **not** stored in Vault (`secret/tailscale/auth` is no longer used — see [ADR-010](adrs/010-tailscale-oauth-ci-generated.md) superseding [ADR-004](adrs/004-tailscale-oauth-seed-strategy.md)). It is created idempotently as a plain Kubernetes `Secret` from CI/local env:

- **CI:** `.github/workflows/deploy.yaml` (trigger `push: branches: [main]` — paths-ignore `docs/**`, `*.md` — plus `workflow_dispatch`, `concurrency: deploy-main`) runs after Tailscale connect + kubeconfig restore:
  ```bash
  kubectl create namespace tailscale --dry-run=client -o yaml | kubectl apply -f -
  kubectl create secret generic operator-oauth -n tailscale \
    --from-literal=client_id="$TS_OAUTH_CLIENT_ID" \
    --from-literal=client_secret="$TS_OAUTH_SECRET" \
    --dry-run=client -o yaml | kubectl apply -f -
  kubectl rollout restart deployment/tailscale-operator -n tailscale || \
    kubectl rollout restart deployment/operator -n tailscale || true
  ```
  This serializes before `bootstrap/init-gitops.sh` and ensures rotation automatically restarts the operator.

- **Local:** `bootstrap/init-gitops.sh:ensureTailscaleCredentials()` (called before `ensureVeleroCredentials()` and before `helm upgrade --install gitops`) does the same `kubectl create secret --dry-run=client | kubectl apply` idempotently. With `--check` it warns but does not mutate:
  ```bash
  TS_OAUTH_CLIENT_ID=... TS_OAUTH_SECRET=... ./bootstrap/init-gitops.sh prod
  TS_OAUTH_CLIENT_ID=... TS_OAUTH_SECRET=... ./bootstrap/init-gitops.sh prod --check  # warn-only
  ```

**Operator consumption:**

`platform/ts-operator` (`1.102.3`, wave `-1` `healthy`) references it via:

```yaml
tailscale-operator:
  oauthSecretName: operator-oauth
  oauth:
    clientID:
      valueFrom: { secretKeyRef: { name: operator-oauth, key: client_id } }
    clientSecret:
      valueFrom: { secretKeyRef: { name: operator-oauth, key: client_secret } }
```

The `tailscale-operator` `Deployment` reads `client_id`/`client_secret` from that `Secret` at start. Re-applying the Secret with a new `client_secret` requires `kubectl rollout restart deployment/tailscale-operator -n tailscale` (handled automatically by `deploy.yaml` and `init-gitops.sh`).

**Why not Vault/ESO:**

`ClusterSecretStore vault-tailscale`, `Job vault-config-tailscale` (`ChangeMeSecret` placeholder), and `ExternalSecret operator-oauth-key` were deleted in ADR-010. The source of truth moved to GitHub Secrets (and local env) to remove Vault UI clickops, to let wave `-1` operator gate waves `0..4` without Vault being in the critical path, and to make `git revert` the rollback.

Verification after bootstrap/sync:

```bash
kubectl -n tailscale get secret operator-oauth -o jsonpath='{.data.client_id}' | base64 -d; echo
kubectl -n tailscale get secret operator-oauth -o jsonpath='{.data.client_secret}' | base64 -d | wc -c
kubectl -n tailscale get pods -l app.kubernetes.io/name=tailscale-operator
argocd app get ts-operator  # should be Healthy/Synced at wave -1
```

## Other Secrets

Additional secrets can be added following these patterns:

- **Vault/ESO path (services that need audit/versioning):** Create them in Vault UI under `secret/` (e.g. `secret/monitoring`) and define a corresponding `ExternalSecret` in the cluster (`platform/*/templates/` + `platform/vault/templates/eso/` `ClusterSecretStore`/`vault-config-*` Job). See [ADR-002](adrs/002-vault-config-decentralization.md).
- **Bootstrap ephemeral outside Vault (Velero precedent, now also Tailscale):** For secrets that must exist *before* Vault/ESO is Ready (Velero backs up Vault; Tailscale operator gates Velero DNS), create an ephemeral plain `Secret` via `bootstrap/init-gitops.sh` (`ensureVeleroCredentials()` / `ensureTailscaleCredentials()`) and reference it via `credentials.existingSecret` / `oauthSecretName`. Follow [ADR-010](adrs/010-tailscale-oauth-ci-generated.md) and [ADR-009](adrs/009-vault-dr-and-velero-backup.md).
