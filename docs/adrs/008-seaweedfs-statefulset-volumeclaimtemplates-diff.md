# ADR-008: SeaweedFS StatefulSet volumeClaimTemplates diff with ServerSideApply

> **Historical (2026-10-13).** The `platform/seaweedfs` chart and its namespace were removed in commit 0759031; S3-compatible storage now comes from the external RustFS endpoint. This ADR is retained as a record of the ArgoCD `ignoreDifferences` / ServerSideApply behaviour; none of the chart, Service, or Namespace paths it references exist anymore.

**Status:** Accepted · **Date:** 2026-08-30

## Context

`platform/seaweedfs` deploys four `StatefulSet`s (`master`, `volume`, `filer`, `admin`) via the upstream Helm chart `seaweedfs 4.44.0` with a thin wrapper (`platform/seaweedfs/Chart.yaml`, `values.yaml`). Since `5d07b2d fix(seaweedfs): add ignoreDifferences for StatefulSet volumeClaimTemplates` the `Application` `seaweedfs` (wave `2`, `gitops/templates/apps/02-seaweedfs.yaml`) declared:

```yaml
ignoreDifferences:
- group: apps
  kind: StatefulSet
  jsonPointers:
  - /spec/volumeClaimTemplates
syncOptions: [CreateNamespace=true, ServerSideApply=true, Retry=true]
```

Despite that, the Application stayed `OutOfSync / Healthy` permanently. ArgoCD UI (Image 1) showed a diff on `seaweedfs-admin` `StatefulSet`:

```diff
 live:  volumeClaimTemplates:
        - apiVersion: v1
          kind: PersistentVolumeClaim
          metadata: {name: admin-data}
          spec: {accessModes: [ReadWriteOnce], resources: {requests: {storage: 1Gi}}, volumeMode: Filesystem}
          status: {phase: Pending}
 desired: volumeClaimTemplates:
        - metadata: {name: admin-data}
          spec: {accessModes: [ReadWriteOnce], storageClassName: "", resources: {requests: {storage: 1Gi}}}
```

Live had `apiVersion`, `kind`, `status` injected by the kube-apiserver. Desired from `helm template` only rendered `metadata.name` + `spec`. The diff never self-healed and `kubectl -n seaweedfs get sts seaweedfs-admin -o json` confirmed live always contained those extra fields.

The parent `Application` `gitops` (app-of-apps, `gitops/templates/root-prod-app.yaml`, `wave-policy: sync-only`) aggregated the child status. With `seaweedfs` `OutOfSync` and its `wave-policy: healthy` (`Synced && Healthy` per ADR-006), `gitops` stayed `OutOfSync / Progressing` (`Syncing`, `waiting for healthy state of argoproj.io/Application/gitops`) in a loop (Image 2). The second symptom was a cascade, not an independent bug.

Root cause is not in the SeaweedFS chart (`values.yaml` correctly sets `storageClass: ""`, `size: 1Gi`) nor in `platform/seaweedfs/templates/`. It is an ArgoCD diffing contract interaction:

- `volumeClaimTemplates` is **immutable** after `StatefulSet` creation. The API server defaults `apiVersion: v1`, `kind: PersistentVolumeClaim`, `metadata.creationTimestamp`, `status` on read. Any `kubectl apply` payload without them is still a diff against live.
- `ServerSideApply=true` switches ArgoCD from `Legacy` (3-way diff via `last-applied-configuration`) to `Structured-Merge Diff` (via `structured-merge-diff` library, fields ownership). That strategy has a known deficiency for defaulted fields in CRDs and `volumeClaimTemplates` — it surfaces `apiVersion`/`kind`/`status` as a diff even though they are server-defaulted. Tracked upstream as `argoproj/argo-cd#11143`, `#4126`, `#24791`.
- `ignoreDifferences` alone only affects the **diff** calculation. During the **sync** phase Argo still applies `desired` as-is via a 3-way merge. Without `RespectIgnoreDifferences=true` the patch still attempts to reconcile `volumeClaimTemplates` and hits the immutability semantic (or re-creates the diff).
- The cluster runs ArgoCD `v3.4.4` (`quay.io/argoproj/argocd:v3.4.4`), where `ServerSideDiff` (dry-run `ServerSideApply` per resource) is GA and is the documented fix for exactly this class of diff.

Additional evidence collected during triage:

- `kubectl -n argocd get application seaweedfs -o json | jq .spec.ignoreDifferences` returned `null` on the live object even though the commit `5d07b2d` contained the fix — the parent `gitops` Application was deadlock-blocked and had not propagated the new `Application` spec.
- `kubectl -n seaweedfs get sts seaweedfs-admin -o json | jq .spec.volumeClaimTemplates` always contained the injected fields; `helm template seaweedfs ./platform/seaweedfs` never did.
- `argocd-cm` health.lua confirms `wave-policy: healthy` gates on `Synced && Healthy`, so `seaweedfs` `OutOfSync` blocked wave `2 -> 3 -> 4`.

## Decision

Fix at the `Application` boundary (`gitops/templates/apps/02-seaweedfs.yaml`), not in the Helm wrapper nor globally in `argocd-cm`. Three coordinated changes:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "2"
    argocd.argoproj.io/tracking-id: gitops:argoproj.io/Application:argocd/seaweedfs
    argocd.argoproj.io/compare-options: ServerSideDiff=true
  labels:
    wave-policy: healthy
spec:
  ignoreDifferences:
  - group: apps
    kind: StatefulSet
    jqPathExpressions:
    - .spec.volumeClaimTemplates[].apiVersion
    - .spec.volumeClaimTemplates[].kind
    - .spec.volumeClaimTemplates[].metadata.creationTimestamp
    - .spec.volumeClaimTemplates[].status
  syncPolicy:
    syncOptions:
      - CreateNamespace=true
      - ServerSideApply=true
      - RespectIgnoreDifferences=true
      - Retry=true
```

Rationale per field:

- **`argocd.argoproj.io/compare-options: ServerSideDiff=true`** — switches this Application from `Structured-Merge Diff` to `ServerSideDiff`. The controller now does a `ServerSideApply --dry-run` per `StatefulSet` and compares the **predicted live** (after admission controllers and defaulting) against the actual live. Server-defaulted `apiVersion`/`kind`/`status` are no longer a diff. This is the upstream-recommended fix (ArgoCD docs: Diff Strategies — Server-Side Diff) and works for both `PersistentVolumeClaim` and upcoming CRDs with defaults. Scoped per-Application to avoid changing diff semantics for the entire controller.
- **`jqPathExpressions` instead of `jsonPointers: /spec/volumeClaimTemplates`** — the previous `jsonPointers` ignored the entire array. That masked the diff but also hid legitimate `spec.resources.requests.storage` or `storageClassName` drift. The new `jqPathExpressions` ignore only the server-injected leaves. If storage size is intentionally changed in `values.yaml`, the diff will still surface (and fail correctly due to immutability, requiring manual PVC migration).
- **`RespectIgnoreDifferences=true`** — makes the sync phase pre-patch `desired` to remove ignored paths before applying. Without it, the diff is hidden in the UI but the apply still sends `volumeClaimTemplates` without `apiVersion`/`kind` and churns. With it, the `StatefulSet` is not patched for those fields at all.

Why not other scopes:

- **Global `argocd-cm` `resource.customizations.ignoreDifferences.apps_StatefulSet`** was rejected — it would hide the same fields for every `StatefulSet` in every Application (including `vault`, `longhorn`), reducing drift visibility. The problem is specific to SeaweedFS's `volumeClaimTemplates` with `ServerSideApply`.
- **Global `ServerSideDiff=true` in `argocd-cm`** was rejected for the same blast-radius reason and because it adds a dry-run API call per resource per reconciliation. Per-Application is cheaper and reversible.
- **Removing `ServerSideApply=true`** would flick back to `Legacy` diff and hide the bug, but `ServerSideApply` is required for other charts (e.g., `monitoring` `ServiceMonitor` label churn) and is the desired long-term apply strategy.

The parent `Application` `gitops` (`gitops/templates/root-prod-app.yaml`) is **not** changed. Its `OutOfSync / Progressing` was a correct aggregation of the child. Once `seaweedfs` became `Synced`, `gitops` returned to `Synced / Healthy` after a hard refresh.

## Alternatives Considered

### Option A — Keep `jsonPointers: /spec/volumeClaimTemplates` + `ServerSideApply=true` (FAILED, status quo)

Hides the entire `volumeClaimTemplates` array in the UI but does not fix `Structured-Merge Diff` defaulting and does not set `RespectIgnoreDifferences`. Verified: `seaweedfs-admin` remained `OutOfSync` with pink/green diff on `apiVersion`/`kind`, and `gitops` stayed `Progressing`.

### Option B — Drop `ServerSideApply=true` for SeaweedFS

Falls back to `Legacy` diff, which ignores `apiVersion`/`kind` via `last-applied-configuration`. Fixes the diff but loses `ServerSideApply` benefits (field ownership, `ServiceMonitor` label handling for `monitoring` dependency). Rejected — the wrapper intentionally enables `ServerSideApply` for all platform apps.

### Option C — Global `ServerSideDiff=true` in `argocd-cm` + global `ignoreDifferences`

```yaml
# argocd-cm
data:
  resource.customizations.ignoreDifferences.apps_StatefulSet: |
    jqPathExpressions:
    - .spec.volumeClaimTemplates[].apiVersion
    - .spec.volumeClaimTemplates[].kind
  argocd-cmd-params-cm:
    server.side.diff.enabled: "true"
```

Fixes SeaweedFS but also changes diff for every `StatefulSet` cluster-wide and adds dry-run cost per resource. Rejected per blast-radius and cost.

### Option D — Per-Application `ServerSideDiff` + granular `jqPathExpressions` + `RespectIgnoreDifferences` (SELECTED)

Scoped, minimal, matches upstream guidance (`argocd/argo-cd#11143` closed by `ServerSideDiff`, `argo-cd#24791` verified fix via annotation). No global config change, no Helm wrapper change.

## Consequences

- **Positive:** `seaweedfs` `StatefulSet`s (`admin`, `filer`, `volume`, `master`) no longer flap `OutOfSync`. `seaweedfs` Application is `Synced / Healthy` with `revision 1a34e4c`. Parent `gitops` is `Synced / Healthy` — wave `2` gates correctly per ADR-006.
- **Positive:** `ServerSideDiff` makes future CRD defaulting bugs (e.g., `monitoring` `ServiceMonitor` `relabelings[].action`) visible as diffs that include admission controller output, improving triage.
- **Positive:** `RespectIgnoreDifferences` guarantees the sync phase does not attempt an immutable `volumeClaimTemplates` patch, avoiding `spec.volumeClaimTemplates: Forbidden: updates to statefulset spec ... are forbidden` on any future re-sync.
- **Negative:** `ServerSideDiff` adds one dry-run `ServerSideApply` call per `StatefulSet` per reconciliation (4 extra calls for SeaweedFS). Negligible at homelab scale; cached and only triggered on `hard-refresh`, `spec` change, or `resourceVersion` change.
- **Negative:** Ignoring `status` and `creationTimestamp` hides any future legitimate drift in those subfields (none expected — `status` is always server-owned).
- **Neutral:** Storage size changes (`values.yaml` `seaweedfs.admin.data.size: 1Gi`, `filer.data.size: 5Gi`, `volume.dataDirs[0].size: 26Gi`) will now correctly show as `OutOfSync` but still be blocked by StatefulSet immutability. Operator must handle PVC resize out-of-band (`kubectl patch pvc` + `sts` recreate) — same as before.
- **Constraint:** Any new `StatefulSet` with `volumeClaimTemplates` added to `platform/seaweedfs` automatically inherits the ignore. A new platform chart with its own `StatefulSet` (e.g., future `apps/`) needs the same per-Application `compare-options` + `ignoreDifferences` if it also uses `ServerSideApply`.

## References

- ArgoCD — Diff Strategies: `Legacy` vs `Structured-Merge Diff` vs `ServerSideDiff` — https://argo-cd.readthedocs.io/en/latest/user-guide/diff-strategies/ — `argocd.argoproj.io/compare-options: ServerSideDiff=true` per-Application
- ArgoCD — Diff Customization — Application `ignoreDifferences` `jqPathExpressions` — https://argo-cd.readthedocs.io/en/stable/user-guide/diffing/
- ArgoCD — Sync Options — `ServerSideApply=true`, `RespectIgnoreDifferences=true` — https://argo-cd.readthedocs.io/en/latest/user-guide/sync-options/
- Upstream issues: `argoproj/argo-cd#4126` (since v1.7 `volumeClaimTemplates` OutOfSync), `#11143` (ServerSideApply diff), `#24791` (`creationTimestamp` with `ServerSideDiff`), `#11106` (StatefulSet stays OutOfSync with ServerSideApply)
- This repo: `gitops/templates/apps/02-seaweedfs.yaml` (fix), `platform/seaweedfs/values.yaml` (wanted `storage: 1Gi`, `5Gi`, `26Gi`), `infra-talos-homelab/modules/platform/values/argocd/values.yaml` (`Application` health.lua `wave-policy`), `docs/adrs/006-app-health-and-vault-ordering.md` (wave semantics)

## Files

| Action | File |
|--------|------|
| Created | `docs/adrs/008-seaweedfs-statefulset-volumeclaimtemplates-diff.md` — this ADR |
| Updated | `gitops/templates/apps/02-seaweedfs.yaml` — add `argocd.argoproj.io/compare-options: ServerSideDiff=true`, replace `jsonPointers` with `jqPathExpressions` for `apiVersion`/`kind`/`creationTimestamp`/`status`, add `RespectIgnoreDifferences=true` |
| Kept | `platform/seaweedfs/values.yaml` — no change (storage sizes remain intentional) |
| Kept | `gitops/templates/root-prod-app.yaml` — no change (parent `OutOfSync` was cascade) |
| Verified | ArgoCD `v3.4.4`, `seaweedfs-admin` `StatefulSet` live `volumeClaimTemplates` with injected `apiVersion`/`kind`/`status: Pending` vs desired without them — now `Synced` via `ServerSideDiff` |

