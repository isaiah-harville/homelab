# Homelab Layout

`clusters/homelab/` is the composition layer for the main homelab k3s cluster.

Folders:
- `flux-system/`: Flux `Kustomization` objects and sync bootstrap
- `infra/`: homelab-specific infrastructure assembly and encrypted infra secrets
- `apps/`: homelab-specific app assembly and encrypted app secrets

In practice:
- `infra/` brings up platform services first
- `apps/` depends on those platform services and then deploys workloads
