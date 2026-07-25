terraform {
  required_version = ">= 1.6.0"

  required_providers {
    omni = {
      source = "siderolabs/omni"
      # Pin the alpha provider and review upgrades manually.
      version = "0.1.0-alpha.3"
    }
  }

  # Rationale and recovery: ../../docs/decisions/terraform-state.md.
  backend "kubernetes" {
    secret_suffix = "omni-homelab"
    namespace     = "arc-runners"
  }
}
