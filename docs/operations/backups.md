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

## Snapshot retention

Omni creates new objects but does not prune older S3 snapshots. The
`seaweedfs-backup-prune` CronJob removes snapshots older than the configured
retention window.

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
