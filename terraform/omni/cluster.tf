resource "omni_cluster" "homelab" {
  name               = local.cluster_name
  talos_version      = local.talos_version
  kubernetes_version = local.k8s_version

  # Provider gap: ../../docs/operations/backups.md.
}

resource "omni_machine_set" "control_plane" {
  cluster = omni_cluster.homelab.name
  role    = "controlplane"

  # Preserve etcd quorum during lifecycle operations.
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
  # Preserve the imported ID: ../../docs/decisions/omni-resource-identity.md.
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
