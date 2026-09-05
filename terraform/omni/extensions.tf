resource "omni_machine_extensions" "base" {
  cluster    = omni_cluster.homelab.name
  extensions = local.base_extensions
}

resource "omni_machine_extensions" "gpu" {
  for_each = toset(local.gpu_nodes)

  cluster    = omni_cluster.homelab.name
  extensions = local.gpu_extensions
  selector = {
    cluster_machine = each.value
  }
}
