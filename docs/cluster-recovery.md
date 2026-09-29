# Cluster recovery

Restore path for this cluster: Velero for PVC/PV + file data, Barman for Postgres, ArgoCD for manifests.

| Layer | Restored by |
|---|---|
| Cilium, ArgoCD | Reinstall from cluster provisioning |
| Workload manifests | ArgoCD auto-sync from Git |
| PVC/PV + file data | Velero (`velero restore create`) |
| Postgres (CNPG) | Barman PITR (§6.7) |
| Vault | Re-bootstrap (§9) |

Two S3 backends. Everything that must survive cluster loss is on external RustFS (`https://rustfs.lonk-mirfak.ts.net`): Velero → `velero-homelab`, Barman → `cnpg-db-backups`. Loki is the only consumer of in-cluster SeaweedFS S3 (`loki-chunks`/`loki-ruler`).

**ArgoCD is reinstalled, never restored.** `daily-full` excludes `argocd` and `kube-system` (`platform/velero/values.yaml:138-155`); every `Application` already lives in Git under `gitops/templates/`.

## 1. Velero state

Chart `platform/velero` — `vmware-tanzu/velero 12.2.0`, app `1.18.2`, AWS plugin `v1.14.3` (digest-pinned). Namespace `velero`, wave `0`.

BackupStorageLocation `default` (`platform/velero/templates/backupstoragelocation.yaml`): RustFS, bucket `velero-homelab`, prefix `velero/`, `us-east-1`, `s3ForcePathStyle: true`, `insecureSkipTLSVerify: true`. The endpoint FQDN is a Git literal — `gitops/values.yaml` → `s3.tailnetFqdn` — and is `required`, so a missing value fails the sync instead of pointing at a dead host.

Credentials are `Secret cloud-credentials` (`platform/velero/values.yaml:77-79`), applied by `bootstrap/init-sops.sh` from `platform/velero/sops/cloud-credentials.enc.yaml`. Fallback: `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` env vars into `bootstrap/init-gitops.sh`.

`job-bucket-init` is an ArgoCD `Sync` hook at wave `0` with `hook-weight: -1`, so it runs first *within* wave 0. It resolves the FQDN, pins it to the in-cluster `s3-egress` Service, and creates the bucket idempotently. Manual equivalent:

```bash
aws s3api create-bucket --bucket velero-homelab \
  --endpoint-url https://rustfs.lonk-mirfak.ts.net --region us-east-1
```

Long-lived pods resolve the FQDN through the `ts.net:53` CoreDNS stub reconciled in `platform/ts-operator`.

### Schedule

`daily-full` — `0 2 * * *`, TTL `720h`, `useOwnerReferencesInBackup: false`.

| Setting | Value |
|---|---|
| `includedResources` | `persistentvolumeclaims`, `persistentvolumes`, `pods` |
| `excludedNamespaces` | `velero`, `kube-system`, `kube-public`, `kube-node-lease`, `longhorn-system`, `vault`, `argocd` |
| `excludedResources` | Longhorn replicas/engines/nodes, ArgoCD Applications/AppProjects/ApplicationSets, Cilium identities/endpoints, events, endpointslices, controllerrevisions, cert-manager ACME objects, Velero's own objects |
| `defaultVolumesToFsBackup` | `true` (node-agent; `snapshotVolumes: false`, no CSI snapshots) |
| `resourcePolicy` | skips the data of every volume on StorageClass `longhorn-cnpg` — Barman owns databases (§2.7) |
| `restoreOnlyMode` | `false` (`values.yaml:69`) |

`pods` is in the allowlist on purpose: without it the node-agent never discovers volumes, and the backup carries no data.

### Verify

```bash
kubectl -n velero get backupstoragelocation default -o jsonpath='{.status.phase}'   # Ready
kubectl -n velero get schedules
velero backup get
```

### Waves

| Wave | Apps | Gate |
|---|---|---|
| `-1` | `ts-operator`, `longhorn`, `cert-manager`, `cloudnative-pg`, `grafana-database` | healthy |
| `0` | `velero` | healthy |
| `1` | `immich-database` | (inside the immich chart) |
| `2` | `seaweedfs` | healthy |
| `3` | `monitoring`, `trivy-operator`, `homepage` | sync-only |
| `5` | `immich` | sync-only |
| `100` | `gitops` root app-of-apps | sync-only |

`vault` and `external-secrets` are gated off (`gitops/values.yaml:19-23`).

## 2. Restore runbook

### 2.1 In-place vs cross-cluster

| | In-place (lost PVCs) | Cross-cluster (new bare metal) |
|---|---|---|
| Cilium / ArgoCD | Untouched | Reinstall first |
| Longhorn | Already Healthy | Install |
| ArgoCD freeze | Required | Required if data lands before the app-of-apps reaches those waves |
| `--existing-resource-policy` | `update` | `update` |

### 2.2 Platform and GitOps first

Velero is installed *by* GitOps, so GitOps must be healthy before any restore can be issued. Do not hand-install Velero.

```bash
./bootstrap/init-sops.sh      # age key from RustFS, then decrypt+apply every sops/*.enc.yaml
./bootstrap/init-gitops.sh prod
```

`init-sops.sh` must run first: SOPS is the live secrets path (ESO is off), and it is what creates the S3 credentials §6 needs. `init-gitops.sh` creates the two platform bootstrap Secrets (Tailscale `operator-oauth`, Velero `cloud-credentials`) and runs `helm upgrade --install gitops`.

```bash
kubectl -n argocd get applications
kubectl -n velero get backupstoragelocation default -o jsonpath='{.status.phase}'   # Ready
```

`Ready` on the BSL also proves RustFS is reachable from inside the cluster.

### 2.3 Freeze GitOps

Every `Application` runs `automated: {prune: true, selfHeal: true}`. Left enabled, `selfHeal` reverts whatever the restore writes. Freeze everything except the two that must stay live to perform the restore — Velero (running the restore) and Longhorn (its CSI provisioner must bind the restored PVCs to the restored PVs):

```bash
kubectl -n argocd get applications -o name | cut -d/ -f2 \
  | grep -vE '^(velero|longhorn)$' > /tmp/frozen-apps.txt
cat /tmp/frozen-apps.txt

while read -r app; do
  kubectl -n argocd patch application "$app" --type merge \
    -p '{"spec":{"syncPolicy":{"automated":null}}}'
done < /tmp/frozen-apps.txt
```

This includes the `gitops` root app-of-apps. It must: the root app owns the child `Application` manifests, so if it stays synced it re-asserts `automated` on every child and silently undoes these patches. Freezing the children but not the parent makes this step look successful and then revert the restore.

§2.8 reads the same file back to unfreeze.

### 2.4 Restore-only mode

Without this, Velero may create or garbage-collect backups while you restore, against a 720h TTL.

```bash
kubectl -n velero patch backupstoragelocation default --type merge \
  -p '{"spec":{"accessMode":"ReadOnly"}}'
```

### 2.5 Pick the backup

```bash
velero backup get
velero backup describe daily-full-<timestamp> --details
velero backup get daily-full-<timestamp> -o json | jq -r '.status.namespaces[]'
```

Only data namespaces appear; the rest are excluded at backup time.

No manual staging is needed for volume data. The restore controller creates the `PodVolumeRestore` objects itself for every pod with associated FSB data.

### 2.6 The restore

```bash
velero restore create dr-$(date +%Y%m%d%H%M) \
  --from-backup daily-full-<timestamp> \
  --exclude-resources pods \
  --existing-resource-policy update \
  --wait
```

- `--exclude-resources pods` — the schedule includes pods so the node-agent can discover volumes, but that also makes Velero try to recreate workloads, which is ArgoCD's job. Excluding them at restore time splits the layers: Velero writes data, ArgoCD writes workloads.
- `--existing-resource-policy update` — the default `none` skips objects GitOps already recreated and leaves stale data behind.

There is no `--include-namespaces` filter. The namespaces that must not be restored are already excluded in the backup, so the backup only contains data namespaces. A list here would be a second copy of that policy that nobody updates, and a stale one silently skips data while the restore still reports success. Adding an app with a PVC requires no change here.

Cluster-scoped objects are not a concern: `includedResources` is a global allowlist, so the only cluster-scoped objects in the backup are the PVs.

For a partial recovery, filter with `--include-namespaces` derived from `.status.namespaces`.

### 2.7 Restore the databases

Velero's FsBackup of a live Postgres is crash-consistent, not a valid recovery path. Both clusters recover through Barman PITR.

| Cluster (namespace) | ObjectStore | Destination | Schedule | Retention |
|---|---|---|---|---|
| `immich-database` (`immich`) | `immich-backup-store` | `s3://cnpg-db-backups/immich/` | `55 1 * * *` | `30d` |
| `grafana-database` (`monitoring`) | `grafana-backup-store` | `s3://cnpg-db-backups/grafana/` | `55 1 * * *` | `30d` |

Both Git manifests render only `bootstrap.initdb` (`apps/immich/templates/pg-immich.yaml:30-33`, `platform/monitoring/templates/grafana-database-cluster.yaml:26-29`) — no `recovery:` stanza, so the recovery manifest below is hand-applied while the app stays frozen (§2.3). Unfreezing is safe afterwards: `bootstrap`/`recovery` only run on empty PGDATA, so Git reconciles over the live object without touching data.

Prerequisites:

1. **S3 Secret in the namespace.** `cnpg-backup-s3-credentials` (keys `ACCESS_KEY_ID` / `SECRET_ACCESS_KEY`) is namespace-local and comes from SOPS (`apps/immich/sops/cnpg-backup-credentials.enc.yaml`, plus the copy in `monitoring/`). §2.2 already applied it. `daily-full` does not back up Secrets.
2. **Know your target.** Omitting `recoveryTarget` replays to the latest WAL. For PITR, `targetTime` needs an explicit timezone (RFC 3339) and must fall inside the `30d` retention:
   ```bash
   kubectl -n immich get backup
   kubectl -n immich get scheduledbackup immich-database-daily -o yaml
   ```
   On a fresh cluster this list is empty — no `ScheduledBackup` has run yet. That is expected, not data loss.
3. **The app stays frozen** until the cluster is primary and verified.

Recovery manifest (immich shown; for grafana use namespace `monitoring`, cluster `grafana-database`, store `grafana-backup-store`, `serverName: grafana-database`, database/owner `grafana`, and no `postgresql:` block — that cluster has none in Git):

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: immich-database
  namespace: immich
spec:
  instances: 2
  imageName: ghcr.io/cloudnative-pg/postgresql:18.6-system-trixie
  bootstrap:
    recovery:
      source: barman-recovery
      # Omit recoveryTarget for latest-WAL recovery; or pin PITR:
      # recoveryTarget:
      #   targetTime: "2026-09-27T01:55:00Z"
      database: immich
      owner: immich
      # No `secret:` — passwords stay as in the backup, so the app
      # credentials in the restored volumes keep working.
  externalClusters:
    - name: barman-recovery
      plugin:
        name: barman-cloud.cloudnative-pg.io
        parameters:
          barmanObjectName: immich-backup-store
          serverName: immich-database
  postgresql:   # verbatim from Git — WAL replay needs the same libraries
    shared_preload_libraries:
      - "vchord.so"
    extensions:
      - name: vchord
        image:
          reference: ghcr.io/tensorchord/vchord-scratch:pg18-v1.1.1
        dynamic_library_path:
          - /usr/lib/postgresql/18/lib
        extension_control_path:
          - /usr/share/postgresql/18/
  storage:
    storageClass: longhorn-cnpg
    size: 2Gi
```

Two differences from the Git manifest, both required:

- **`bootstrap.recovery` + `externalClusters` added** — the recovery itself. `serverName` must equal the original cluster name. On version drift the installed CRDs are authoritative: `kubectl explain cluster.spec.externalClusters`.
- **The `plugins:` WAL-archiver section removed.** A recovery cluster that archives to the same store + serverName trips the operator's empty-archive safety check (`ERROR: WAL archive check failed ... Expected empty archive`, stuck in `Setting up primary`). Recover read-only; §2.8 re-adds the archiver from Git after promotion. Do not work around it with `cnpg.io/skipEmptyWalArchiveCheck`.

Procedure per database:

```bash
# 0. Only when the data is actually gone, so the operator does not bootstrap
#    an empty initdb over the wreckage.
kubectl -n immich delete cluster immich-database
kubectl -n immich get pvc -l cnpg.io/cluster=immich-database

# 1. Apply, then watch until primary:
kubectl apply -f immich-database-recovery.yaml
kubectl -n immich get cluster immich-database -w

# 2. Verify:
kubectl -n immich get cluster immich-database -o jsonpath='{.status.phase}{"\n"}'
# Cluster in healthy state
```

Postgres volumes use StorageClass `longhorn-cnpg`, so they are excluded twice: from every Longhorn RecurringJob by its `recurringJobGroup: no-snapshot`, and from the Velero backup by the `resourcePolicy` on `daily-full` (`platform/velero/values.yaml`), which skips the data of every volume on that class. The PVC and PV objects still come back, so the volume mounts empty and Barman fills it.

### 2.8 Unfreeze

Release GitOps in dependency order — the databases must be primary before the apps that consume them:

```bash
# 1. SeaweedFS: Loki inside `monitoring` needs its S3 endpoint serving.
kubectl -n argocd patch application seaweedfs --type merge \
  -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
kubectl -n seaweedfs get pods

# 2. Gate:
kubectl -n immich get cluster immich-database -o jsonpath='{.status.phase}{"\n"}'
kubectl -n monitoring get cluster grafana-database -o jsonpath='{.status.phase}{"\n"}'
# Cluster in healthy state × 2 — otherwise stop here.

# 3. Everything else that was frozen, read back from the same list.
#    This also restores the WAL-archiver `plugins:` section.
grep -v '^seaweedfs$' /tmp/frozen-apps.txt | while read -r app; do
  kubectl -n argocd patch application "$app" --type merge \
    -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
done

kubectl -n velero patch backupstoragelocation default --type merge \
  -p '{"spec":{"accessMode":"ReadWrite"}}'
```

### 2.9 Validate

First, the mechanical preconditions. A restore that did not reach `Completed` is not a candidate for validation, and `Bound` PVCs prove nothing on their own — a PVC can be `Bound` on an empty volume with every application running happily over it.

```bash
velero restore get
velero restore describe dr-<timestamp> --details | grep -E 'Phase|Items restored|Errors'
velero restore logs dr-<timestamp> | grep 'level=error'
kubectl -n immich get cluster immich-database         # healthy, 2 instances
kubectl -n monitoring get cluster grafana-database    # healthy, 2 instances
kubectl -n argocd get applications                    # Synced / Healthy
```

Then verify the data itself — **[Restore verification](./restore-verification.md)**. Two application-level signals, each one reading data that cannot exist unless the restore returned real content: historical metrics, and an Immich image uploaded before the disaster.

### 2.10 Restore troubleshooting

| Symptom | Fix |
|---|---|
| Restore `PartiallyFailed` | `velero restore describe <name>`; pre-existing objects are skipped unless `--existing-resource-policy update` was set |
| Restore completes, volumes empty | Expected for databases — the `resourcePolicy` skips their data and Barman fills the volume (§2.7). For any other volume, confirm the backup actually carried FSB data: `velero backup describe <name> --details` and look for the PVC under `Pod Volume Backups - kopia`. An empty volume with no FSB entry in the backup was never backed up, not lost in transit. |
| ArgoCD reverts restored objects | The `gitops` root app was not frozen (§2.3) — it re-asserts `automated` on every child |
| Workloads do not come back | Expected — ArgoCD owns them |
| `BSL not Ready` after unfreeze | The `ReadOnly` patch in §2.4 was not reverted |
| Postgres restored but inconsistent | Use Barman, not Velero (§2.7) |
| Recovery stuck `Setting up primary` + `Expected empty archive` | The manifest kept the `plugins:` archiver section — remove it, re-apply (§2.7) |
| WAL replay fails on `vchord` | The manifest dropped `spec.postgresql` — copy it verbatim from Git (§2.7) |
| PITR target never reached | `targetTime` outside the `30d` retention or missing timezone (§2.7) |
| Apps CrashLoop after unfreeze, DBs healthy | Both clusters must be primary before their apps (§2.8 step 2) |
| `NoSuchBucket` or `velero` unreachable | RustFS is gone — see [RustFS IAM](./rustfs-iam.md) |

## 3. Velero troubleshooting

| Symptom | Fix |
|---|---|
| `cloud-credentials not found` | Re-run `init-sops.sh` with env vars |
| `NoSuchBucket` | `kubectl -n velero logs job/velero-bucket-init` |
| `BSL not Ready` | Verify `s3Url`/`s3ForcePathStyle` and the ini format |
| `nslookup` fails | Check the `ts.net:53` stub, `DNSConfig ts-dns` status IP, then the `s3-egress` endpoints and the bucket-init `/etc/hosts` pin |
| Velero OOMKilled | Memory limit is `512Mi`; `deployNodeAgent: true` is required for `defaultVolumesToFsBackup: true` |

## 4. References

- ADR-004 option A (bootstrap Secret outside Vault), ADR-009 (Vault DR), ADR-011 (DNS/NetworkPolicy), ADR-017 (SOPS as the secrets path)
- Restore: [Velero disaster-recovery docs](https://velero.io/docs/main/disaster-case) and [Red Hat — OADP + OpenShift GitOps DR](https://www.redhat.com/en/blog/oadp-openshift-gitops-an-approach-to-implementing-application-disaster-recovery)
- Proving the restore worked: [Restore verification](./restore-verification.md)
- Postgres: [CNPG 1.29 — Recovery](https://cloudnative-pg.io/docs/1.29/recovery), [Barman Cloud Plugin — Main Concepts](https://cloudnative-pg.io/plugin-barman-cloud/docs/concepts/)
- Chart and values: `platform/velero/Chart.yaml`, `platform/velero/values.yaml`
- Barman ObjectStores: `apps/immich/templates/pg-immich.yaml:56-73`, `platform/monitoring/templates/grafana-database-cluster.yaml:64-81`
- ArgoCD Application: `gitops/templates/platform/00-velero.yaml`
- S3 key material: [RustFS IAM](./rustfs-iam.md)

## 5. Vault

Vault is excluded from `daily-full` and is never restored from Velero — restoring Raft state from a backup corrupts the cluster. Vault holds no irreplaceable material, so DR is re-bootstrap:

```bash
./platform/vault/scripts/bootstrap-vault.sh   # init, unseal, kv-v2 + k8s auth
```

Hourly protection is a Longhorn local snapshot: RecurringJob `vault-hourly-snapshot` (`0 * * * *`, `snapshot`, retain 24, group `vault-hourly`). Match it to a volume by labelling the `Volume` CR with `recurring-job-group.longhorn.io/vault-hourly=enabled`.

See [ADR-009](adrs/009-vault-dr-and-velero-backup.md) §Decision 1.
