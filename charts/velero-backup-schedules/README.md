# velero-backup-schedules

A backup *policy* for Velero, as values. Velero (the [vmware-tanzu/velero](https://github.com/vmware-tanzu/helm-charts) chart) does the backing up; this chart says what, when, for how long, proves the backups restore, and alerts when they stop.

- **Schedules**: daily (7 days), weekly (30 days), monthly (90 days) by default; any number, each overriding the shared defaults (namespaces, resources, volume snapshots or file-system backup, label selectors, CSI timeouts, hooks).
- **Locations** (optional): a `BackupStorageLocation` and `VolumeSnapshotLocation` for AWS, GCP or Azure.
- **Restore test**: a CronJob that restores the latest backup of a schedule into a scratch namespace, waits for the pods to become Ready, reports pass or fail, and cleans up. Monthly by default; weekly for anything that matters.
- **Alerts** (optional): backup failed, partially failed, too old per schedule, never ran, restore test failed.

## Install

```bash
helm repo add oreonit https://oreondev.github.io/helm-charts
helm install backups oreonit/velero-backup-schedules -n velero -f backups.yaml
```

`backups.yaml`:

```yaml
defaults:
  excludedNamespaces: [kube-system, kube-public, kube-node-lease, velero, monitoring]

schedules:
  - name: daily
    schedule: "0 2 * * *"
    ttl: 168h
    maxAgeHours: 26
  - name: weekly
    schedule: "0 3 * * 0"
    ttl: 720h
    maxAgeHours: 192
    includeClusterResources: true
  - name: payments-hourly
    schedule: "0 * * * *"
    ttl: 48h
    maxAgeHours: 2
    includedNamespaces: [payments]
    defaultVolumesToFsBackup: true

restoreTest:
  enabled: true
  schedule: "0 6 * * 1"        # Mondays 06:00
  fromSchedule: daily
  namespace: payments
  minReadyPods: 2

monitoring:
  enabled: true
  labels:
    release: kube-prometheus-stack
```

Run the restore test by hand the first time:

```bash
kubectl -n velero create job --from=cronjob/backups-velero-backup-schedules-restore-test restore-test-manual
kubectl -n velero logs -f job/restore-test-manual
```

## How the restore test works

1. Finds the newest `Completed` backup of `restoreTest.fromSchedule`.
2. Creates a Velero `Restore` of `restoreTest.namespace` mapped into `<namespace>-restore-test` (volumes included).
3. Waits for the restore to complete, then for pods in the scratch namespace to become Ready (`restoreTest.waitTimeout`).
4. Passes if at least `restoreTest.minReadyPods` pods are Ready; fails otherwise. Deletes the scratch namespace and the Restore object afterwards (`restoreTest.cleanup`).

A failed job is a failed test. With `monitoring.enabled` the `VeleroRestoreTestFailed` alert fires; without it, kube-prometheus-stack's `KubeJobFailed` still does.

Things the test cannot see: applications that come up Ready but have lost data, Secrets managed by an external operator, DNS or ingress names that differ in the scratch namespace. Read the restored app's logs the first few times.

## Values

| Key | Default | Description |
|---|---|---|
| `veleroNamespace` | `velero` | Where Velero runs |
| `storageLocation.create` | `false` | Create a BackupStorageLocation (`provider`, `bucket`, `prefix`, `config`, `credential`, `default`, `accessMode`, `backupSyncPeriod`) |
| `volumeSnapshotLocation.create` | `false` | Create a VolumeSnapshotLocation (`provider`, `config`, `credential`) |
| `defaults.*` | see values.yaml | Shared backup template: `storageLocation`, `volumeSnapshotLocations`, `includedNamespaces`, `excludedNamespaces`, `includedResources`, `excludedResources`, `includeClusterResources`, `snapshotVolumes`, `defaultVolumesToFsBackup`, `labelSelector`, `csiSnapshotTimeout`, `hooks`, `paused`, `skipImmediately`, `maxAgeHours` |
| `schedules[]` | daily / weekly / monthly | `name`, `schedule` (cron), `ttl`, plus any default override |
| `restoreTest.enabled` | `false` | Create the restore-test CronJob, ServiceAccount and RBAC |
| `restoreTest.schedule` / `fromSchedule` / `namespace` | monthly / `daily` / required | What to test |
| `restoreTest.targetNamespace` | `<namespace>-restore-test` | Scratch namespace |
| `restoreTest.waitTimeout` / `minReadyPods` / `cleanup` | `30m` / `1` / `true` | Pass criteria |
| `restoreTest.image` | `bitnami/kubectl:1.31` | Any image with bash and kubectl |
| `monitoring.enabled` | `false` | PrometheusRule (needs Velero metrics scraped and kube-state-metrics) |
| `monitoring.labels` | `{}` | Prometheus Operator ruleSelector labels |

## Notes

- Velero's own install is a prerequisite: the server, the cloud plugin, node agent if you use file-system backup, and a credentials Secret. `kubectl -n velero get bsl` must say `Available` before the first schedule fires.
- Retention is `ttl` on the backup; Velero deletes expired backups from the bucket. Match it to your recovery point objective and to what the bucket lifecycle rules do.
- `includeClusterResources: true` on one schedule (weekly here) captures CRDs, ClusterRoles and StorageClasses for a full-cluster rebuild; leave it unset on the others.
- The restore-test ClusterRole can delete namespaces. It is bound to one ServiceAccount in the Velero namespace; keep that namespace locked down.

The plan this slots into is the [disaster recovery plan template](https://www.oreonit.com/disaster-recovery-plan-template-for-cloud-teams/); if you would like the whole plan written and tested, see our [disaster recovery planning](https://www.oreonit.com/disaster-recovery-planning-services/).

## Licence

MIT. Maintained by [Oreon IT](https://www.oreonit.com/).
