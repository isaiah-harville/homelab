# Metrics Server kubelet TLS

Status: accepted

## Context

Metrics Server scrapes kubelet endpoints to provide resource metrics used by
`kubectl top` and dashboard consumers. The Talos kubelet certificates in this
cluster are not signed by the Kubernetes cluster CA that Metrics Server uses
for verification.

## Decision

Pass `--kubelet-insecure-tls` to Metrics Server.

## Consequences

- Kubelet certificate authenticity is not verified by Metrics Server.
- Scrape traffic remains on the node network.
- Resource metrics remain available without introducing a separate kubelet
  certificate issuance process.
- Revisit this decision if kubelet certificates become verifiable through a
  CA bundle supported by the deployment.
