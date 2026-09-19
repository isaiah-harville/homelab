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

Every volume gets a daily Longhorn snapshot. The volumes that cannot be
fetched again also get a weekly Longhorn backup to Cloudflare R2 (see
"Off-site copies"); media files, model caches, Prometheus history and Orion's
frames are deliberately left out of that.

`seaweedfs-backup-prune` must never delete anything under `config/`. Removing a
WAL segment or base backup by age breaks the recovery chain that the remaining
backups depend on, so the CronJob explicitly ignores that prefix.

Failures are alerted on rather than discovered later: `CNPGBackupFailing`,
`CNPGNoRecentBackup` and `CNPGWALArchiveFailing` in
`apps/authentik/authentik/app/postgres-alerts.yaml`. The WAL alert matters most — WAL
archiving can break while nightly base backups keep succeeding, silently
removing point-in-time recovery between them.

## Off-site copies

SeaweedFS is itself backed by Longhorn volumes on these nodes, so on its own it
covers application-level loss but not loss of the cluster or its disks. Two
jobs copy state to Cloudflare R2 (bucket `homelab-backups`, credentials in
`infrastructure/longhorn-system/longhorn/app/longhorn-r2.sops.yaml`):

| What | How | When |
| --- | --- | --- |
| Postgres base backups and WAL, Omni snapshots | `offsite-backup-sync` CronJob (rclone) mirrors the whole `backups` bucket to `seaweedfs-backups/` | nightly, 05:00 |
| The 13 volumes labelled `recurring-job-group.longhorn.io/offsite` | Longhorn `weekly-backup` recurring job, to `longhorn/` | Sundays, 03:00 |

`sync` mirrors deletions too, so barman's 30-day retention applies off-site
as well; R2 is a copy of the current backup set, not a second archive.

A volume opts in through its PVC labels in Git. Longhorn keeps that membership
on the Volume and never copies it from the PVC, so the hourly `offsite-labels`
job propagates the labels; a volume labelled in Git but missing from the group
is the failure to look for.

Restoring is the reverse: a Longhorn backup restores to a new volume from the
backup target, and a Postgres cluster restores with `bootstrap.recovery` as
described in [Flux layout and moves](flux-layout.md).

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
   `apps/seaweedfs/seaweedfs/app/backup-prune-cronjob.yaml`.
2. Leave enough overlap to retain multiple usable snapshots.
3. Verify the CronJob can authenticate to the backup bucket.
4. Confirm recent snapshots remain after a manual job run.

## Home automation

The home-automation stack has five `longhorn-retain` PVCs:

- `otbr-data`: active Thread operational dataset and OTBR state.
- `matter-server-data`: Matter fabric, credentials, and commissioned nodes.
- `zigbee2mqtt-data`: Zigbee network key, device database, names, and backups.
- `mosquitto-data`: broker database and retained MQTT messages.
- `home-assistant-config`: Home Assistant database, `.storage`, dashboards,
  integrations, automations, scripts, scenes, and HomeKit pairing state.

Restore them in that order: OTBR, Matter Server, Zigbee2MQTT, Mosquitto, then
Home Assistant. Restore the Thread and Matter volumes from compatible recovery
points; restoring only one can invalidate device commissioning state.

The default recurring-job group retains seven daily Longhorn snapshots, and all
five volumes are also in the `offsite` group, so a weekly copy lives in R2.
Snapshots are the fast local recovery points; R2 is what survives losing the
cluster. Export and protect the Thread dataset separately before an OTBR
migration, and do not
create a replacement Thread network during recovery.

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
