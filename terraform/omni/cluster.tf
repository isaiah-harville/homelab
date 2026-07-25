resource "omni_cluster" "homelab" {
  name               = local.cluster_name
  talos_version      = local.talos_version
  kubernetes_version = local.k8s_version
}

resource "omni_machine_set" "control_plane" {
  cluster = omni_cluster.homelab.name
  role    = "controlplane"

  # Roll config changes and Talos/k8s upgrades ONE control-plane node at a time so
  # etcd keeps quorum throughout. Applying these is a safe in-place update (Omni
  # just records the strategy — no node churn).
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
