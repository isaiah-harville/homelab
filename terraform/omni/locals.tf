# Keep this topology aligned with talos/omni/cluster-template.yaml.
locals {
  cluster_name  = "homelab"
  talos_version = "1.13.5"
  k8s_version   = "1.33.3"

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

  # Per-machine install patch: file (patch YAML) + name. The name must match the
  # patch name Omni already stores (cluster-template.yaml uses these), so the
  # config-patch IDs line up and Terraform adopts them in place instead of
  # recreating: 400-cm-<uuid>-<name>.
  install_patch = {
    "4c4c4544-0030-5910-805a-c6c04f503133" = { file = "install-type-nvme.yaml", name = "install-nvme" } # 256GB NVMe OS
    "4c4c4544-0039-4210-8046-b8c04f314a33" = { file = "install-le400gb.yaml", name = "install-256" }    # 256GB NVMe OS
    "4c4c4544-0052-3610-8039-cac04f484733" = { file = "install-ge100gb.yaml", name = "install-single" } # 512GB NVMe OS
    "9ba21500-a881-11e5-ae5a-d524518f0c00" = { file = "install-ge100gb.yaml", name = "install-single" } # 256GB SSD OS
    "30393137-3436-584d-5135-343430303635" = { file = "install-dl380.yaml", name = "install-dl380" }    # OS on sda by wwid
  }

  storage_nodes = [
    "4c4c4544-0030-5910-805a-c6c04f503133",
    "4c4c4544-0039-4210-8046-b8c04f314a33",
    "30393137-3436-584d-5135-343430303635",
  ]
}
