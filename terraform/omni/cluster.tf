resource "omni_cluster" "homelab" {
  name               = local.cluster_name
  talos_version      = local.talos_version
  kubernetes_version = local.k8s_version

  # etcd backups to the seaweedfs "backups" bucket, configured via the
  # EtcdBackupS3Configs resource (applied out-of-band with omnictl, since the
  # provider has no resource for it). Requires the omni container to be
  # started with --etcd-backup-s3 (see omni-server/compose.yaml).
  # Omni's interval is relative (since last backup), not clock-aligned, so
  # this lands roughly once a day rather than at a guaranteed time of day.
  backup_configuration = {
    interval = "24h"
  }
}

resource "omni_machine_set" "control_plane" {
  cluster = omni_cluster.homelab.name
  role    = "controlplane"

  # Roll config changes and Talos/k8s upgrades ONE control-plane node at a time so
  # etcd keeps quorum throughout.
  update_strategy = {
    type            = "Rolling"
    max_parallelism = 1
  }
  upgrade_strategy = {
    type            = "Rolling"
    max_parallelism = 1
  }
}

resource "omni_machine_set_node" "control_plane" {
  for_each = toset(local.control_plane_nodes)

  cluster     = omni_cluster.homelab.name
  machine_set = omni_machine_set.control_plane.name
  machine_id  = each.value
}

resource "omni_machine_set" "workers" {
  cluster = omni_cluster.homelab.name
  # No explicit name: Omni defaults the set to "<cluster>-workers"
  # (homelab-workers), same as the unnamed control-plane set. Setting a short
  # "workers" name diverges from that ID and forces a destructive replace.
  role = "workers"

  update_strategy = {
    type            = "Rolling"
    max_parallelism = 1
  }
  upgrade_strategy = {
    type            = "Rolling"
    max_parallelism = 1
  }
}

resource "omni_machine_set_node" "workers" {
  for_each = toset(local.worker_nodes)

  cluster     = omni_cluster.homelab.name
  machine_set = omni_machine_set.workers.name
  machine_id  = each.value
}
