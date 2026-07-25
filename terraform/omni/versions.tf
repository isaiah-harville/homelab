terraform {
  required_version = ">= 1.6.0"

  required_providers {
    omni = {
      source = "siderolabs/omni"
      # Pin the alpha provider and review upgrades manually.
      version = "0.1.0-alpha.3"
    }
  }

  # State lives in a Kubernetes Secret in the cluster (Omni remains the real
  # source of truth — lost state is re-imported, see README). The in-cluster ARC
  # runner reaches it via its ServiceAccount; local runs use a kubeconfig.
  #
  # Why not S3/SeaweedFS: Terraform's S3 backend (AWS SDK v2) writes state with a
  # chunked STREAMING-UNSIGNED-PAYLOAD-TRAILER upload that SeaweedFS rejects
  # (403 InvalidAccessKeyId). Reads work, writes don't, and there's no client
  # knob to disable it — so the k8s backend is the reliable choice here.
  #
  # Connection resolves from the environment:
  #   - CI (runner pod):  KUBE_IN_CLUSTER_CONFIG=true  (set on the runner)
  #   - local:            KUBE_CONFIG_PATH=<kubeconfig>
  # State Secret: tfstate-omni-homelab, lock Lease: lock-omni-homelab (arc-runners).
  backend "kubernetes" {
    secret_suffix = "omni-homelab"
    namespace     = "arc-runners"
  }
}
