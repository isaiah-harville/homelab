# Terraform state backend

Status: accepted

## Context

Terraform runs from the in-cluster Actions runner and manages the Omni cluster.
The state backend must support locking, work from both the runner and a local
recovery session, and remain recoverable if its state is lost.

SeaweedFS was evaluated through Terraform's S3 backend. Reads succeeded, but
writes from the AWS SDK v2 used a chunked
`STREAMING-UNSIGNED-PAYLOAD-TRAILER` upload that SeaweedFS rejected with
`InvalidAccessKeyId`. Terraform did not expose a client setting to disable that
upload behavior.

## Decision

Use Terraform's Kubernetes backend. It stores state in a Secret and coordinates
locking with a Lease.

The in-cluster runner authenticates through its ServiceAccount. Local recovery
uses a kubeconfig. Omni remains the source of truth, so the Terraform resources
can be imported again if state is lost.

## Consequences

- CI does not need separate state-storage credentials.
- State availability depends on the Kubernetes API.
- A total cluster loss requires rebuilding the cluster and importing the Omni
  resources into fresh state.
- Backend resources and access are documented in the
  [Terraform runbook](../terraform/omni/README.md).
