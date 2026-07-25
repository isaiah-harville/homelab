# Apps Layout

`apps/base/` contains workloads whose Kubernetes resources are maintained in this
repository. Most are a HelmRelease or a small Deployment/Service/Ingress bundle.

`apps/releases/` contains applications sourced from another Git repository. The
usual directory contains:

- a Flux `GitRepository`
- a Flux `Kustomization` pointing at deployment manifests in that repository
- an ingress and any cluster-local integration

`openvitae` is different: its external repository supplies a Helm chart, so this
repository contains the `HelmRelease` directly.

Both kinds are selected by `clusters/homelab/apps/kustomization.yaml`; adding a
directory under `apps/` does not deploy it by itself.
