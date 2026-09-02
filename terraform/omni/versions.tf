terraform {
  required_version = ">= 1.6.0"

  required_providers {
    omni = {
      source = "siderolabs/omni"
    }
  }

  # Rationale and recovery: ../../docs/decisions/terraform-state.md.
  backend "kubernetes" {
    secret_suffix = "omni-homelab"
    namespace     = "arc-runners"
  }
}
