terraform {
  required_version = ">= 1.6.0"

  required_providers {
    omni = {
      source  = "siderolabs/omni"
      version = "0.1.0-beta.0"
    }
  }

  # Rationale and recovery: ../../docs/decisions/terraform-state.md.
  backend "kubernetes" {
    secret_suffix = "omni-homelab"
    namespace     = "arc-runners"
  }
}
