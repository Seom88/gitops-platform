# Restore verification

How to tell that a cluster recovery actually recovered the data, as opposed to merely producing a running cluster.

Run this after the restore described in [Cluster recovery](./cluster-recovery.md). It is the complement of that document, not a replacement: the runbook issues the restore, this one judges it.

## What counts as proof

A green pod is not proof. A `Bound` PVC is not proof. Velero can create a `Bound` PVC on an empty Longhorn volume, every application will start, and the dashboards will render — over nothing. Availability and data are separate claims and only one of them is what a restore is supposed to deliver.

So this document carries exactly two signals, both of them application-level, because both read data that existed before the disaster and cannot exist after a restore that lost it:

| Signal | Reads | Proves |
|---|---|---|
| [Metrics](#signal-1-metrics) | Prometheus TSDB, Loki chunks | the Velero FsBackup layer returned file data to PVCs and to SeaweedFS-backed storage |
| [Immich images](#signal-2-immich-images) | a Postgres row **and** a SeaweedFS blob, at the same instant | the Barman PITR layer and the Velero FsBackup layer are both correct, in the same app |

Nothing else is listed here on purpose. Do not add a check that only proves something is reachable.

## Before you verify anything

Two ordering facts decide whether a failure is real. Check them first, so a green-to-red result is not misread as a broken restore.

```bash
# 1. The Velero backup must predate the loss you are recovering from.
velero backup get -o wide
```

If the backup's `Started` is later than the data you expect, the data was never in the backup. That is a scheduling problem, not a restore problem.

```bash
# 2. Immich images only exist in the backup if Barman ran after they were added.
kubectl -n immich get scheduledbackups
```

The immich check is a two-layer test. If its base backup predates the images, the test fails for a correct reason. Wait for the next run (`55 1 * * *`) before drawing any conclusion.

---

## Signal 1 — Metrics

Historical series do not come back from a manifest sync. A series with a timestamp before the disaster can only be present if the TSDB files were restored with their content.

### Prometheus

```bash
just pf-prometheus     # kubectl port-forward svc/prometheus-kube-prometheus-prometheus -n monitoring 9090:9090
```

Pick a timestamp comfortably **before** the disaster — a week back is a good choice, well clear of the edge of the retention window.

```bash
BEFORE="2026-09-20T12:00:00Z"

# Decisive: how many series existed at that instant?
curl -sG http://localhost:9090/api/v1/query \
  --data-urlencode 'query=count(up)' \
  --data-urlencode "time=$BEFORE" | jq -r '.data.result[0].value[1]'

# Stronger: an actual continuous series across the window, not one stale sample.
curl -sG http://localhost:9090/api/v1/query_range \
  --data-urlencode 'query=up' \
  --data-urlencode "start=$BEFORE" \
  --data-urlencode "end=$BEFORE" --data-urlencode 'step=60' \
  | jq '.data.result[0].values | length'
```

**Pass** — a number greater than zero, and a non-empty `values` array.
**Fail** — `0`, a null, or an empty array.

A `Fail` here means the `prometheus-...-db` PVC came back empty. The TSDB was a file-level backup, so there is no second path to it: go to [cluster recovery §2.10](./cluster-recovery.md#210-restore-troubleshooting).

### Loki

Loki's chunks live in SeaweedFS S3 and its index in its own PVC, so this is the one signal that crosses the two storage layers at once.

```bash
just pf-grafana       # kubectl port-forward svc/prometheus-grafana -n monitoring 3000:80
```

Open Explore, pick the Loki datasource, and query:

```logql
{namespace="immich"}
```

with the time range set **before** the disaster.

**Pass** — log lines from before the disaster. **Fail** — no lines, or only lines dated after it.

An empty result with chunks present usually means the index PVC came back without its content while the objects survived in S3. A completely empty result means the SeaweedFS volume did too.

---

## Signal 2 — Immich images

Opening a photo is the single most complete check available. It is not one assertion but two, resolved by one action:

- the asset row comes from Postgres, restored by **Barman PITR**
- the image bytes come from SeaweedFS, restored by **Velero FsBackup**

Either layer failing produces a broken or empty thumbnail. A passing thumbnail requires both.

```bash
just pf-grafana   # or open the Immich UI on the tailnet
```

1. Log in.
2. Open the timeline.
3. Open one image uploaded **before** the disaster and let it render at full size.

**Pass** — the image renders. Confirm it is a real photo and not a placeholder.

Corroborate with the row count, which needs no schema knowledge:

```bash
kubectl -n immich exec immich-database-1 -- \
  psql -U postgres -d immich \
  -c "select relname, n_live_tup from pg_stat_user_tables order by n_live_tup desc limit 10"
```

**Pass** — the tables carry row counts, and the assets table is the largest.

A row count with no image means Barman restored the database correctly and Velero did not restore the SeaweedFS volume. Rows with no image is the expected failure mode of recovering only the Barman layer; treat it as a missed Velero restore, not as database damage.

## When a signal fails

The two failures point at different layers, and the distinction is the useful part:

| Failing signal | Layer | Where to look |
|---|---|---|
| Metrics only, Immich rows present | Velero FsBackup for a normal PVC | §2.6, then §2.10 |
| Immich rows present, images absent | Velero FsBackup for SeaweedFS | §2.6, then the SeaweedFS row in §2.10 |
| Both metrics and images fail | the whole Velero data layer — check the restore itself before the storage | §2.5, §2.6 |
| Immich rows absent | Barman PITR, not Velero | §2.7 |

Databases are never recovered from the Velero backup — `daily-full` skips the data of every volume on StorageClass `longhorn-cnpg` on purpose. If the rows are missing, the failure is in the recovery manifest or the `targetTime`, and no amount of re-running the Velero restore will change it.

## Reference

- [Cluster recovery](./cluster-recovery.md) — issuing the restore
- `apps/immich/values.yaml` — the `backup` block (schedule, retention, object store)
- `platform/velero/values.yaml` — `daily-full` and the `resourcePolicy` that excludes database volumes
