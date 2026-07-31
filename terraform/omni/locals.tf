# Keep this topology aligned with talos/omni/cluster-template.yaml.
locals {
  cluster_name  = "homelab"
  talos_version = "1.13.5"
  k8s_version   = "1.36.3"

  patch_dir = "${path.module}/../../talos/omni/patches"
  control_plane_nodes = [
    "4c4c4544-0030-5910-805a-c6c04f503133",
    "4c4c4544-0039-4210-8046-b8c04f314a33",
    "4c4c4544-0052-3610-8039-cac04f484733",
  ]
  worker_nodes = [
    "9ba21500-a881-11e5-ae5a-d524518f0c00", # thinkcentre-01
    "30393137-3436-584d-5135-343430303635", # dl380
  ]

  # Patch names are identity: ../../docs/decisions/omni-resource-identity.md.
  install_patch = {
    "4c4c4544-0030-5910-805a-c6c04f503133" = { file = "install-type-nvme.yaml", name = "install-nvme" } # 256GB NVMe OS
    "4c4c4544-0039-4210-8046-b8c04f314a33" = { file = "install-le400gb.yaml", name = "install-256" }    # 256GB NVMe OS
    "4c4c4544-0052-3610-8039-cac04f484733" = { file = "install-ge100gb.yaml", name = "install-single" } # 512GB NVMe OS
    "9ba21500-a881-11e5-ae5a-d524518f0c00" = { file = "install-ge100gb.yaml", name = "install-single" } # 256GB SSD OS
    "30393137-3436-584d-5135-343430303635" = { file = "install-dl380.yaml", name = "install-dl380" }    # OS on sda by wwid
  }

  # Dedicated disks are claimed as Talos UserVolumes. Root-disk nodes only
  # need the kubelet bind mount and the Longhorn disk-creation label.
  dedicated_storage_nodes = [
    "4c4c4544-0030-5910-805a-c6c04f503133",
    "4c4c4544-0039-4210-8046-b8c04f314a33",
    "30393137-3436-584d-5135-343430303635",
  ]
  root_storage_nodes = [
    "4c4c4544-0052-3610-8039-cac04f484733",
    "9ba21500-a881-11e5-ae5a-d524518f0c00",
  ]
  storage_nodes = concat(local.dedicated_storage_nodes, local.root_storage_nodes)
}
