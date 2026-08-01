# Backup and recovery

The recovery model separates management-plane state, Terraform state,
Kubernetes secrets, and application data. They have different backup and
restore paths.

## Omni state

Omni stores its embedded databases under the `data/` directory on its host.
Back up the complete runtime state while the Compose stack is stopped; the
[Omni runbook](../omni-server/README.md#backup-and-restore) contains the
commands and the full file list.

Omni also creates interval-based etcd snapshots in object storage. Snapshot
creation is enabled in the Omni configuration and the cluster template.

The pinned Terraform provider does not expose the cluster backup configuration.
The S3 backup resource and interval are therefore configured with `omnictl`,
while Terraform continues to manage the supported cluster fields.

## Authentik database

Authentik's Postgres is the one piece of application state that cannot be
rebuilt from Git: users, groups, OIDC providers and flows exist only there.
CloudNativePG backs it up to the `backups` bucket in SeaweedFS under
`config/authentik-postgres` — continuous WAL archiving plus a nightly base
backup at 01:30, which together give point-in-time recovery rather than a
once-a-day image. Retention is `backup.retentionPolicy` on the Cluster, set to
30 days; CNPG prunes its own backups.

Other application volumes are covered only by the daily Longhorn snapshot. That
is a deliberate trade: everything else is either rebuildable, replaceable, or
not worth the object storage.

`seaweedfs-backup-prune` must never delete anything under `config/`. Removing a
WAL segment or base backup by age breaks the recovery chain that the remaining
backups depend on, so the CronJob explicitly ignores that prefix.

Failures are alerted on rather than discovered later: `CNPGBackupFailing`,
`CNPGNoRecentBackup` and `CNPGWALArchiveFailing` in
`apps/base/authentik/postgres-alerts.yaml`. The WAL alert matters most — WAL
archiving can break while nightly base backups keep succeeding, silently
removing point-in-time recovery between them.

This is not disaster recovery. SeaweedFS is itself backed by Longhorn volumes on
the same nodes, so it covers application-level loss but not loss of the cluster
or the disks. Pointing `destinationPath` and the credentials Secret at off-site
S3 would close that gap with no other changes.

## Snapshot retention

Omni creates new objects but does not prune older S3 snapshots. The
`seaweedfs-backup-prune` CronJob removes snapshots older than the configured
retention window.

The CronJob walks the top-level prefixes of the `backups` bucket and prunes each
one except `config/`. Omni writes its snapshots under a per-cluster UUID prefix,
so this covers them; loose objects at the bucket root are not pruned.

The backup interval is relative to the previous backup rather than aligned to a
wall-clock schedule. The pruning schedule is therefore a best-effort offset,
not a guaranteed "run immediately after backup" time.

When changing retention:

1. Update the age passed to `mc rm` in
   `apps/base/seaweedfs/backup-prune-cronjob.yaml`.
2. Leave enough overlap to retain multiple usable snapshots.
3. Verify the CronJob can authenticate to the backup bucket.
4. Confirm recent snapshots remain after a manual job run.

## Terraform state

Terraform state uses the Kubernetes backend. If the state Secret is lost, Omni
remains authoritative and the resources can be imported again. See the
[state backend decision](../decisions/terraform-state.md) and the
[Terraform runbook](../terraform/omni/README.md#if-state-is-lost).

## SOPS identity

The age private key is not stored in Git. Keep an encrypted external copy and
restore the `flux-system/sops-age` Secret before encrypted Flux
Kustomizations reconcile.

## Recovery order

1. Restore or start Omni.
2. Recreate the Talos cluster and obtain a kubeconfig.
3. Restore the SOPS age identity.
4. Bootstrap or reconcile Flux.
5. Restore application data where reconciliation alone is insufficient.
6. Re-import Terraform resources if its Kubernetes state was lost.
