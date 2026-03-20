# Apps Layout

`apps/base/` contains in-repo workload manifests for the shared `apps` namespace.

`apps/releases/` contains source-backed app definitions:
- a Flux `GitRepository`
- the app ingress and cluster-local files
- a Flux `Kustomization` that points at the external repo
