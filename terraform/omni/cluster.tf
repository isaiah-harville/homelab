resource "omni_cluster" "homelab" {
  name               = local.cluster_name
  talos_version      = local.talos_version
  kubernetes_version = local.k8s_version
}

resource "omni_machine_set" "control_plane" {
  cluster = omni_cluster.homelab.name
  role    = "controlplane"
  # Strategies left unset to match the omnictl template (and the live cluster) —
  # Omni's default rolling behavior applies. Setting them here would diverge from
  # the imported state.
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
}

resource "omni_machine_set_node" "workers" {
  for_each = toset(local.worker_nodes)

  cluster     = omni_cluster.homelab.name
  machine_set = omni_machine_set.workers.name
  machine_id  = each.value
}
