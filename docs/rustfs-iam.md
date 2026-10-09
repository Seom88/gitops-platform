# RustFS IAM — Per-Service Backup Keys

> **Scope:** RustFS is an **external system** (separate VM, managed outside this repo).
> This doc is the runbook for creating least-privilege S3 keys for cluster
> consumers (Velero, CNPG shared DB backups). Cluster side (SOPS + bootstrap fallback) is
> wired here; the keys themselves are created in RustFS and never committed.

## Concepts (what matters here)

- **Service accounts (Access Keys)** are derived credentials owned by a parent
  user. They inherit the parent's permissions, **optionally restricted further
  by an embedded session policy**, and can carry an expiration time.
  They are the right shape for app keys: one per consumer, scoped, expirable.
- **Session policy = intersection**: parent policies AND session policy must
  both allow. A session policy can only *narrow*, never widen.
- **"Use main account policy" toggle** (Console): when ON, the key inherits
  the parent's full policy. Our parent is root-equivalent (`admin:*`,
  `kms:*`, `s3:*` on `arn:aws:s3:::*`) — **always leave it OFF** for service
  keys and attach a scoped session policy instead.
- Reference: [RustFS IAM](https://docs.rustfs.com/en/security-compliance/iam),
  [policies](https://docs.rustfs.com/en/security-compliance/iam/policies),
  [service accounts](https://docs.rustfs.com/en/security-compliance/iam/sts).

## Console flow (verified 2026-09-21)

Console → left nav **Access Keys** → **Add Access Key** (top right) →
**Create Key** dialog:

1. **Name**: `velero-backup` / `cnpg-backup`. **Description**: what it is
   for (e.g. `Velero daily backups - homelab`, `CNPG shared DB backups - homelab`).
2. **Access Key**: leave blank to autogenerate; if Submit complains, type the
   name by hand. **Secret Key** comes pre-generated (masked).
3. **Expiry**: set ~1 year out (e.g. `2027-09-21`). Empty = permanent;
   acceptable in a homelab but then rotation never happens — prefer expirable
   and calendar the rotation (see below).
4. **"Use main account policy"**: leave **OFF**.
5. If a policy box appears with the toggle off, paste the scoped JSON for the
   consumer (see examples). If no policy box appears, Submit anyway and scope
   afterwards via admin API — the key is still isolated from root, scoping is
   follow-up, not blocker.
6. On confirm the pair is shown **once** — Copy/Export immediately, there is
   no second chance.

## Scoped policies

Backups need **delete** (Velero prunes by TTL, Barman by its
`retentionPolicy`), so these allow `s3:DeleteObject` — scoped to the single
bucket. (A WORM/archive key would deny deletes; not our case.)

### Velero (`velero-homelab`)

`s3:CreateBucket` is required: the `velero-bucket-init` Job creates the
bucket idempotently with the scoped key itself (scoped to this one ARN, so
least-privilege still holds — the key cannot create or touch any other
bucket).

Mirrors the upstream [minimal policy](https://github.com/velero-io/velero-plugin-for-aws/)
(EC2 snapshot actions omitted — no EBS here; `GetBucketLocation` added: harmless
read that helps `head-bucket`/diagnostics). No `ListAllMyBuckets` — Velero never
lists buckets, it goes straight to its own:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:GetBucketLocation", "s3:ListBucket", "s3:CreateBucket"],
      "Resource": ["arn:aws:s3:::velero-homelab"]
    },
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"],
      "Resource": ["arn:aws:s3:::velero-homelab/*"]
    }
  ]
}
```

### CNPG shared (`cnpg-db-backups`)

One bucket + one key for all CNPG databases (homelab decision 2026-09-28:
replaces per-DB SeaweedFS IAM users). Each Cluster keeps its own
`ObjectStore` pointing at a per-DB prefix (`s3://cnpg-db-backups/immich/`,
`s3://cnpg-db-backups/grafana/`), so WAL + base backups never collide while
rotation stays a single key.

`s3:CreateBucket` is intentionally omitted: the bucket is created once manually
in console (no bucket-init Job per user decision 2026-09-28).

Verified 2026-10-09 by signing every call with the real `cnpg-backup` key
(read/write probe from inside the cluster, each operation executed against
`https://rustfs.lonk-mirfak.ts.net` — status codes below are observed, not
inferred). Barman needs three distinct **bucket-level listing** verbs that were
missing; that is exactly what made retention fail on *both* clusters while
base backups kept succeeding:

| Verb | Who needs it | Observed before the fix |
| --- | --- | --- |
| `s3:ListBucketVersions` | **retention.** barman's catalogue enumerates `list_object_versions()` to compute the recovery window, so `barman-cloud-backup-delete` cannot even start without it | 403 |
| `s3:ListBucketMultipartUploads` | enumerating abandoned multipart uploads | 403 |
| `s3:GetBucketVersioning` | barman probes bucket versioning before deciding its delete strategy | 403 |

The trap: `s3:ListMultipartUploadParts` (object ARN) is **not** the same
permission as `s3:ListBucketMultipartUploads` (bucket ARN). The first was
already granted, which is why uploads and aborts worked while retention
did not. Symptom on the cluster: `RetentionPolicyFailed` on
`immich-database` and `grafana-database` once every ~5 minutes, with every
`ScheduledBackup` reporting `completed`.

Confirmed working, deliberately kept: `HeadBucket`/`ListObjectsV2`
(`s3:ListBucket`), `s3:GetBucketLocation`, `s3:GetObject`, `s3:PutObject`,
`CreateMultipartUpload`/`UploadPart` (`s3:PutObject`),
`s3:ListMultipartUploadParts`, `s3:AbortMultipartUpload`, `s3:DeleteObject`.

No version-related verbs (`s3:DeleteObjectVersion`, `s3:GetObjectVersion`):
the bucket is **not** versioned — verified by `HeadObject` on a live object,
which returns no `x-amz-version-id`. Add them only if versioning is ever
switched on, because with versioning live `s3:DeleteObject` writes a delete
marker and stops freeing space.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetBucketLocation",
        "s3:ListBucket",
        "s3:ListBucketVersions",
        "s3:ListBucketMultipartUploads",
        "s3:GetBucketVersioning"
      ],
      "Resource": ["arn:aws:s3:::cnpg-db-backups"]
    },
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"],
      "Resource": ["arn:aws:s3:::cnpg-db-backups/*"]
    }
  ]
}
```

**Apply in RustFS console** (key `cnpg-backup`): paste the JSON above as the
session policy, then confirm with `kubectl get events -n immich --field-selector reason=RetentionPolicyFailed` — the count must stop increasing and no new `RetentionPolicyFailed` may appear.

Manual step (once): create bucket `cnpg-db-backups` in console before the first
backup. No cluster-side provisioning — the old SeaweedFS `backup-init` IAM flow
is gone with `charts/cnpg` (deleted 2026-09-28).

### Sharing one key + one bucket across namespaces

CNPG `ObjectStore.s3Credentials` is namespace-local, so the same `cnpg-backup`
key material is duplicated as one Secret per consumer namespace (same keys,
different namespaces — not two different keys):

Blast-radius note: one leaked key affects all DB backups (vs per-DB keys).
Accepted for homelab (2 DBs); revisit per-DB keys if the fleet grows or
compliance requires isolation.

## Cluster handoff (SOPS — operator encrypts, never shares plaintext)

1. Scaffolds already exist with `CHANGEME` placeholders — replace the values
   with the real keys (shapes below for reference):
   `platform/velero/sops/cloud-credentials.enc.yaml`,
   `apps/immich/sops/cnpg-backup-credentials.enc.yaml` +
   `platform/monitoring/sops/cnpg-backup-credentials.enc.yaml`
   (same `cnpg-backup` key material in both — one logical credential, one
   Secret per namespace because CNPG `ObjectStore.s3Credentials` is
   namespace-local).
   Then encrypt from the repo root per [docs/sops.md](sops.md):
2. Exact Secret shapes (no Helm templating inside `.enc.yaml` — pure YAML):

   `platform/velero/sops/cloud-credentials.enc.yaml`:
   ```yaml
   apiVersion: v1
   kind: Secret
   metadata:
     name: cloud-credentials
     namespace: velero
   stringData:
     cloud: |-
       [default]
       aws_access_key_id=<velero key>
       aws_secret_access_key=<velero secret>
   ```

   CNPG shared — same key material twice (one Secret per consumer namespace;
   `bootstrap/init-sops.sh` applies every `*/sops/*.enc.yaml`):

   `apps/immich/sops/cnpg-backup-credentials.enc.yaml`:
   ```yaml
   apiVersion: v1
   kind: Secret
   metadata:
     name: cnpg-backup-s3-credentials
     namespace: immich
   stringData:
     ACCESS_KEY_ID: <cnpg-backup key>
     SECRET_ACCESS_KEY: <cnpg-backup secret>
   ```

   `platform/monitoring/sops/cnpg-backup-credentials.enc.yaml`:
   ```yaml
   apiVersion: v1
   kind: Secret
   metadata:
     name: cnpg-backup-s3-credentials
     namespace: monitoring
   stringData:
     ACCESS_KEY_ID: <cnpg-backup key>
     SECRET_ACCESS_KEY: <cnpg-backup secret>
   ```

    Converge each app's `backup.secretName` to `cnpg-backup-s3-credentials` and
    keep per-DB prefixes in the direct manifests (`destinationPath:
    s3://cnpg-db-backups/<app>/`, e.g. `immich/`, `grafana/` in
    `apps/immich/templates/pg-immich.yaml` and
    `platform/monitoring/templates/grafana-database-cluster.yaml` — no library
    chart since 2026-09-28). The bucket is pre-created manually in console;
    no bucket-init Job, no IAM provisioning from the cluster.
3. Apply: `just secrets-apply` (decrypt + `kubectl apply`, shreds key after).
4. `bootstrap/init-gitops.sh` (`ensureVeleroCredentials`) stays as
   **fallback**: if the Secret already exists via SOPS and no env creds are
   set, it does not touch it; env creds still allow bootstrap/rotation
   without SOPS.

## Automation (Terraform)

Short answer: possible, not recommended yet.

- Community provider [`weinmann-emt/rustfs`](https://github.com/weinmann-emt/terraform-provider-rustfs)
  (`~> 0.0.7`, ~15 stars, MPL-2.0) exposes `rustfs_user` (with `policy`),
  `rustfs_serviceaccount`, `rustfs_policy`, `rustfs_group`. It exists precisely
  because `mc admin` does not work against RustFS
  ([issue #567](https://github.com/rustfs/rustfs/issues/567)).
- Caveats: immature (pin the version, test against dev first); the provider
  author's own note says IAM support was bolted on; `secret_key` lands in
  **Terraform state in plaintext** — acceptable only with an encrypted
  backend; and RustFS itself lives in the **infra repo**, so this code would
  not live here anyway.
- `rc` CLI gained user creation (`v0.1.2`) but policy attach was still
  `NotImplemented` ([issue #1571](https://github.com/rustfs/rustfs/issues/1571));
  raw admin API (`PUT /rustfs/admin/v3/...`, SigV4-signed) is always available
  as escape hatch.
- **Decision (2026-09-21): console for now (2 keys), revisit when key count
  grows or the provider matures.** ClickOps on an external box twice a year
  beats maintaining TF glue against a 15-star provider.
- **Decision (2026-09-28): same for the 3rd key (`cnpg-backup`).** No
  cluster-side IAM provisioning against RustFS (the SeaweedFS `backup-init`
  IAM flow does not port: `mc admin` unsupported, Terraform provider
  immature, `rc` policy-attach incomplete). Bucket creation stays automated
  via the scoped-key bucket-init Job; user/key creation stays console +
  SOPS.

## Rotation

1. Create the replacement key in console (same name + `-next`, same policy).
2. Re-encrypt the SOPS file(s) (`sops platform/<chart>/sops/<name>.enc.yaml` —
   for CNPG re-encrypt **both** `apps/immich/sops/cnpg-backup-credentials.enc.yaml`
   and `platform/monitoring/sops/cnpg-backup-credentials.enc.yaml` with the same
   pair),
   `just secrets-apply`, verify the consumer works (Velero BSL Available /
   CNPG `head-bucket` + one `ScheduledBackup` succeeds).
3. Disable (don't delete yet) the old key → wait one backup cycle → delete.
