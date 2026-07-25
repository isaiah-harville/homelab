# Patch YAML is shared with the omnictl template.
resource "omni_config_patch" "allow_scheduling" {
  name    = "allow-scheduling"
  cluster = omni_cluster.homelab.name
  # Cluster-wide patches land at weight 200 in Omni (200-cluster-...); match it
  # so Terraform adopts the existing patch instead of recreating it.
  weight = 200
  data   = file("${local.patch_dir}/allow-scheduling.yaml")
}

resource "omni_config_patch" "controlplane_vip" {
  name    = "controlplane-vip"
  cluster = omni_cluster.homelab.name
  weight  = 400
  selector = {
    machine_set = omni_machine_set.control_plane.name
  }
  data = file("${local.patch_dir}/controlplane-vip.yaml")
}

resource "omni_config_patch" "install" {
  for_each = local.install_patch

  name    = each.value.name
  cluster = omni_cluster.homelab.name
  weight  = 400
  selector = {
    cluster_machine = each.key
  }
  data = file("${local.patch_dir}/${each.value.file}")
}

resource "omni_config_patch" "longhorn_disk" {
  for_each = toset(local.storage_nodes)

  name    = "longhorn-disk"
  cluster = omni_cluster.homelab.name
  weight  = 401
  selector = {
    cluster_machine = each.value
  }
  data = file("${local.patch_dir}/longhorn-disk.yaml")
}

resource "omni_config_patch" "longhorn_storage_node" {
  for_each = toset(local.storage_nodes)

  name    = "longhorn-storage-node"
  cluster = omni_cluster.homelab.name
  weight  = 402
  selector = {
    cluster_machine = each.value
  }
  data = file("${local.patch_dir}/longhorn-storage-node.yaml")
}
