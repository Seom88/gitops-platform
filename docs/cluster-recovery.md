# Cluster recovery

Restore path: Velero for PVC/PV + file data, Barman for Postgres, ArgoCD for manifests.

| Layer | Restored by |
|---|---|
| Cilium, ArgoCD | Reinstall from cluster provisioning |
| Workload manifests | ArgoCD sync from Git (manual while frozen) |
| PVC/PV + file data | Velero, step 4 |
| Postgres (CNPG) | Barman PITR, step 5 |
| Vault | Re-bootstrap, see Vault at the end |

Survival storage is external RustFS (`https://rustfs.lonk-mirfak.ts.net`): Velero → `velero-homelab`, Barman → `cnpg-db-backups`. Loki is the only consumer of in-cluster SeaweedFS S3.

**ArgoCD is reinstalled, never restored.** `daily-full` excludes `argocd` and `kube-system`; every `Application` already lives in Git under `gitops/templates/`.

## 1. What is in the backups

Chart `platform/velero`, namespace `velero`. BSL `default`: bucket `velero-homelab`, prefix `velero/`.

Schedule `daily-full` — `0 2 * * *`, TTL `720h`:

| Includes | Excludes |
|---|---|
| `persistentvolumeclaims`, `persistentvolumes`, `pods` (without pods in the backup the node-agent cannot discover volumes, and without restored pods there is no `PodVolumeRestore` target) | `velero`, `kube-system*`, `longhorn-system`, `vault`, `argocd`, Velero/ArgoCD/Cilium-owned objects, events |
| | Anything labeled `cnpg.io/cluster` (DB PVCs and pods): dropped by the schedule `labelSelector` (`DoesNotExist`), so restores never replant DB shells — proven with a selector-only test backup, Oct 2026 |
| | Postgres data: excluded by `resourcePolicy` on every `longhorn-cnpg` volume — databases go via Barman |

```bash
kubectl -n velero get backupstoragelocation default -o jsonpath='{.status.phase}'   # Ready
velero backup get
```

## 2. Restore, step by step

### Step 0 — Platform and GitOps first

GitOps installs Velero: without healthy GitOps there is no restore. Never install Velero by hand.

```bash
just init-prod # Create secrets and install apps
```

If it fails with `Permission denied` in `bootstrap/`: `chmod +x bootstrap/*.sh` and retry.

### Step 1 — Freeze GitOps

Every `Application` runs `automated: {prune, selfHeal}`: left alive, it reverts whatever the restore writes mid-flight (observed: CNPG killing pods with `FindingCluster Unknown` while Velero was still in `restore-wait`). A `deny` window on the `default` project — where the 12 apps live, and which is not in Git so nothing reverts it — freezes all syncs, automatic and manual, leaving UI and health alive:

```bash
# ArgoCD login: `just pf-argocd` in another terminal, password from `just argocd-password`.
# If an operation is Running, terminate it first: argocd app terminate-op <app>
argocd proj windows add default --kind deny \
  --schedule '* * * * *' --duration 24h \
  --applications '*' --description "DR restore freeze"
argocd proj windows list default   # verify; note the id for step 6
```

The window lasts 24h: if the restore runs long, syncs resume on their own. Re-check before long steps; if it expires, delete and re-add. Cross-cluster (new bare metal): same freeze, applied as soon as GitOps is up and before data apps sync.

Single-app alternative (proven on `immich`, Oct 2026): instead of the project window, disable auto-sync, selfHeal and prune on that one `Application` only. Cheaper blast radius, same effect — nothing reconciles while Velero works.

### Step 2 — Pause backups and quiesce workloads

The `02:00` `daily-full` must not fire mid-restore (snapshot of half-restored volumes + contention with the node-agent):

```bash
velero schedule pause daily-full
```

Quiesce: scaling workloads to 0 first **does help** — the restore writes data into the bound volume, and a pod already running on a freshly created empty volume writes live files over the incoming data. Worst case observed: a CNPG `initdb` bootstrapping on top of ruins. With the step-1 freeze, ArgoCD does not fight the scale-down, and deleting the freeze returns replicas from Git. The list comes from live PVCs — exactly the volumes the restore is about to fill:

```bash
kubectl get pvc -A -o json \
  | jq -r '.items[] | select(.spec.storageClassName // "" | startswith("longhorn")) | .metadata.namespace' \
  | sort -u | grep -vE '^(tailscale|velero|longhorn-system|argocd|kube-system|vault|cnpg-system)$' \
  > /tmp/quiesce-ns.txt
cat /tmp/quiesce-ns.txt

while read -r ns; do
  kubectl -n "$ns" scale deploy --all --replicas=0 2>/dev/null || true
  kubectl -n "$ns" scale statefulset --all --replicas=0 2>/dev/null || true
done < /tmp/quiesce-ns.txt
```

`vault` is excluded because Raft is not touched (re-bootstraps, see below); `cnpg-system` is the operator, not data. Rules: never delete a PVC "to make room" *before* the restore (depending on reclaim policy it takes the Longhorn volume with it) — the only exception is the post-restore deletion of provably empty DB shells in step 5.0; if there is an HPA, delete it for the window (`kubectl -n <ns> delete hpa --all`, Git recreates it); the databases go further — the `Cluster` is deleted so the operator does not bootstrap (step 5).

### Step 3 — Pick the backup

```bash
velero backup get
velero backup describe daily-full-<timestamp> --details
```

Step 2 quiesced every namespace with a Longhorn volume, so any backup is covered. Verify it carries data: in the describe's `Pod Volume Backups`, every PVC must have an entry. No entry means it was never backed up. No manual staging: the restore creates the `PodVolumeRestore` objects on its own.

### Step 4 — Velero restore (app-of-apps pattern)

Manual-sync the Application first so ArgoCD creates manifests and **fresh, dynamically provisioned PVCs**; then Velero restores only the data on top. Velero writes data, ArgoCD writes workloads — each owns its layer, no fight:

```bash
# 1. ArgoCD creates the empty scaffolding (manual sync — autosync is frozen):
argocd app sync <app>
kubectl -n <ns> get pvc   # fresh PVCs Bound, volumes empty — expected

# 2. Velero fills the data. Do NOT exclude pods: restored pods carry the
#    `restore-wait` init container and are the PodVolumeRestore target.
velero restore create dr-$(date +%Y%m%d%H%M) \
  --from-backup daily-full-<timestamp> \
  --include-namespaces <ns> \
  --wait
```

Default `--existing-resource-policy none` is correct here: ArgoCD-created PVCs are skipped (kept), and the `PodVolumeRestore` downloads the kopia snapshots into the live volumes. Pods sit in `Init:restore-wait` while data downloads — that is normal progress, not stuck. Track it with `velero restore describe <name>` (`kopia Restores: In Progress/Prepared`) — `Bound` PVC alone proves nothing, it can be bound on top of an empty volume.

Full-DR variant (namespace empty, nothing synced yet): same command without the prior manual sync — the restore creates the PVCs itself and Longhorn provisions new volumes. If a restored PVC stays `Pending` pointing at a gone volume (`spec.volumeName` of a deleted PV), clear it and let the provisioner retry:

```bash
kubectl -n <ns> patch pvc <name> -p '{"spec":{"volumeName":""}}'
```

### Step 5 — Databases (Barman, not Velero)

A live Postgres FsBackup is crash-consistent: not valid recovery. Both clusters go via PITR:

| Cluster (namespace) | ObjectStore | Destination |
|---|---|---|
| `immich-database` (`immich`) | `immich-backup-store` | `s3://cnpg-db-backups/immich/` |
| `grafana-database` (`monitoring`) | `grafana-backup-store` | `s3://cnpg-db-backups/grafana/` |

Restored or fresh DB volumes are empty by design — Barman fills them, not Velero. But the restore replants the database *objects* (PVCs and pods ride along in `includedResources`; only the data is skipped), and those shells block recovery: the CNPG operator reconciles a franken-state of initdb Cluster + empty replanted PVCs + stale same-named pods, and bootstrap never gets a clean shot. Clean slate first, recovery second. Git manifests only carry `bootstrap.initdb` — no `recovery:` stanza — so recovery is applied by hand with the app frozen. Unfreezing afterwards is safe: `bootstrap`/`recovery` only run on empty PGDATA, Git reconciles without touching data.

Prerequisites: secret `cnpg-backup-s3-credentials` in the namespace (comes from SOPS, applied in step 0; `daily-full` does not back up Secrets). For PITR, `targetTime` with explicit timezone inside the 30d retention (`kubectl -n immich get backup` to see what exists; on a fresh cluster an empty list is normal, not loss).

Manifest (immich; grafana: namespace `monitoring`, cluster `grafana-database`, store `grafana-backup-store`, `serverName: grafana-database`, database/owner `grafana`, no `postgresql:` block):

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

Two differences from Git, both mandatory:

- **`bootstrap.recovery` + `externalClusters`** — the recovery. `serverName` = original name. On version drift see `kubectl explain cluster.spec.externalClusters`.
- **No `plugins:` WAL-archiver section.** A recovery archiving to the same store + serverName stalls at `Setting up primary` (`Expected empty archive`). It recovers read-only; step 6 re-adds it from Git. Never use `cnpg.io/skipEmptyWalArchiveCheck`.

```bash
# 0. Clean slate — MANDATORY for backups taken before the schedule
#    `labelSelector` (Oct 2026); those replant empty DB PVCs and stale DB
#    pods that block recovery. Skip this step for newer backups — the
#    selector already dropped everything labeled `cnpg.io/cluster`. For old
#    backups: the volumes are empty by design (resourcePolicy `skip` => no
#    PodVolumeBackup), so deleting the PVCs loses nothing; reclaim `Delete` removes the shells. The recovery
#    Cluster below makes CNPG provision truly fresh PVCs itself.
kubectl -n immich delete cluster immich-database --ignore-not-found
kubectl -n immich delete pod -l cnpg.io/cluster=immich-database --ignore-not-found
kubectl -n immich delete pvc -l cnpg.io/cluster=immich-database --ignore-not-found

# 1. Apply and wait for primary:
kubectl apply -f immich-database-recovery.yaml
kubectl -n immich get cluster immich-database -w

# 2. Verify:
kubectl -n immich get cluster immich-database -o jsonpath='{.status.phase}{"\n"}'
# Cluster in healthy state
```

### Step 6 — Unfreeze

In order: databases must be primary before their apps. The window froze syncs without nulling policies, so there is no loop to replay — reopen in stages with the same window (id from step 1):

```bash
# 1. Manual syncs only — automatic ones stay blocked:
argocd proj windows enable-manual-sync default <window-id>

# 2. SeaweedFS first: Loki in `monitoring` needs its S3 serving.
argocd app sync seaweedfs
kubectl -n seaweedfs get pods   # serving before moving on

# 3. Gate — both primary or stop here:
kubectl -n immich get cluster immich-database -o jsonpath='{.status.phase}{"\n"}'
kubectl -n monitoring get cluster grafana-database -o jsonpath='{.status.phase}{"\n"}'
# Cluster in healthy state × 2.

# 4. Everything else at once. Deleting the window resumes automatic
#    syncs; Git returns the recovery Clusters to their manifest
#    (initdb + archiver `plugins:`) — safe on live PGDATA.
argocd proj windows delete default <window-id>

velero schedule unpause daily-full
```

Single-app freeze: re-enable auto-sync/selfHeal/prune on the Application instead. Then clean up Velero-restored workload pods (same names, older ReplicaSet hashes linger while prune was off) so ArgoCD owns the workloads again — data persists in the volumes:

```bash
kubectl -n <ns> delete pods --all   # ArgoCD recreates them on live data
```

### Step 7 — Validate

Mechanical preconditions (a non-`Completed` restore is not validated; `Bound` PVC proves nothing — it can be bound over an empty volume):

```bash
velero restore get
velero restore describe dr-<timestamp> --details | grep -E 'Phase|Items restored|Errors'
velero restore logs dr-<timestamp> | grep 'level=error'
kubectl -n immich get cluster immich-database         # healthy, 2 instances
kubectl -n monitoring get cluster grafana-database    # healthy, 2 instances
kubectl -n argocd get applications                    # Synced / Healthy
```

Then the real data — **[Restore verification](./restore-verification.md)**: historic metrics + one Immich photo older than the disaster.

## 3. If something fails

| Symptom | Fix |
|---|---|
| Restore `PartiallyFailed` | `velero restore describe <name>`; pre-existing objects are skipped unless `--existing-resource-policy update` |
| Restore OK, volumes empty | Normal for DBs — Barman fills them (step 5). Other volumes: confirm the backup carried FSB (`velero backup describe --details`, find the PVC under `Pod Volume Backups`). No entry means never backed up |
| ArgoCD reverts restored state | The `deny` window is missing, expired, or does not cover `*` (step 1) — `argocd proj windows list default` |
| Syncs running mid-restore | 24h window expired (delete + re-add, step 1) or a manual sync with manual-sync enabled (step 6.1) |
| Restored PVC `Pending` with a stale `volumeName` | The PV is gone (reclaim `Delete`) — `kubectl -n <ns> patch pvc <name> -p '{"spec":{"volumeName":""}}'` and Longhorn provisions fresh (step 4) |
| Pods sit in `Init:restore-wait` | Normal — kopia data is downloading. Watch `velero restore describe` (`kopia Restores`), not the pod state |
| Velero `restore-wait` init container survives on unrelated pods | Known Velero quirk ([#8870](https://github.com/vmware-tanzu/velero/issues/8870)) — harmless, ArgoCD recreates clean pods on next sync |
| Duplicate workload pods after unfreeze | Prune was off during restore — delete restored pods, ArgoCD recreates them on the restored volumes (step 6) |
| Workloads do not return | Normal — they belong to ArgoCD, they return when the freeze is lifted |
| No new backups after recovery | Missing `velero schedule unpause daily-full` (step 6) |
| Postgres inconsistent | Via Barman, not Velero (step 5) |
| Recovery stalls / initdb never runs | Velero-replanted DB PVCs, pods, or Cluster in the way — clean slate per step 5.0 before applying recovery |
| Recovery stuck `Setting up primary` + `Expected empty archive` | Manifest kept `plugins:` — remove and re-apply (step 5) |
| WAL replay fails on `vchord` | Missing verbatim `spec.postgresql` from Git (step 5) |
| PITR never arrives | `targetTime` outside the 30d window or missing timezone (step 5) |
| Apps CrashLoop after unfreeze, DBs healthy | Both DBs must be primary before their apps (step 6.3) |
| `NoSuchBucket` or Velero unreachable | RustFS down — [RustFS IAM](./rustfs-iam.md). If the bucket is gone: `aws s3api create-bucket --bucket velero-homelab --endpoint-url https://rustfs.lonk-mirfak.ts.net --region us-east-1` |
| `BSL not Ready` | Check `s3Url`/`s3ForcePathStyle`, Secret `cloud-credentials` (`bootstrap/init-sops.sh`), and tailnet DNS: `coredns-custom` exists in `kube-system`, tailscaled runs with `--accept-dns` on the node, `nslookup rustfs.lonk-mirfak.ts.net` succeeds from a pod |
| Velero OOMKilled | `512Mi` limit; `deployNodeAgent: true` mandatory with `defaultVolumesToFsBackup: true` |

## 4. Vault

Vault is excluded from `daily-full` and never restored from Velero — restoring Raft corrupts the cluster. It holds nothing irreplaceable: DR is re-bootstrap:

```bash
./platform/vault/scripts/bootstrap-vault.sh   # init, unseal, kv-v2 + k8s auth
```

Hourly protection: local Longhorn snapshot via RecurringJob `vault-hourly-snapshot` (`0 * * * *`, retain 24). To match it to a volume, label the `Volume` with `recurring-job-group.longhorn.io/vault-hourly=enabled`.

See [ADR-009](adrs/009-vault-dr-and-velero-backup.md).

## 5. References

- Restore: [Velero disaster-recovery docs](https://velero.io/docs/main/disaster-case) and [Red Hat — OADP + OpenShift GitOps DR](https://www.redhat.com/en/blog/oadp-openshift-gitops-an-approach-to-implementing-application-disaster-recovery)
- Proving it worked: [Restore verification](./restore-verification.md)
- Postgres: [CNPG 1.29 — Recovery](https://cloudnative-pg.io/docs/1.29/recovery), [Barman Cloud Plugin](https://cloudnative-pg.io/plugin-barman-cloud/docs/concepts/)
- Chart and values: `platform/velero/Chart.yaml`, `platform/velero/values.yaml`
- S3: [RustFS IAM](./rustfs-iam.md)

## 6. Lessons learned (immich pilot, Oct 2026)

- The ArgoCD fight was the root cause from the start, not background noise: CNPG `FindingCluster Unknown` + pod killing while Velero restored. Freeze first, always.
- Velero-pure restore into pre-existing PVCs is a dead end: Velero never writes into an existing PVC and never resets a stale `spec.volumeName`. Fresh PVCs (from ArgoCD) + data-only restore is the pattern.
- Manual kopia-in-a-pod was a detour: it trades one solved problem for three new ones (S3 endpoint format, secret hygiene, node inotify limits). Stay on the native path.
- Quiescing (scale to 0) before restore prevents live writes on empty volumes and CNPG bootstrap races.
