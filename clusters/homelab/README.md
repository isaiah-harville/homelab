# Homelab Layout

`clusters/homelab/` is the composition layer for the main homelab Talos cluster.

Folders:
- `flux-system/`: Flux `Kustomization` objects and sync bootstrap
- `infra/`: homelab-specific infrastructure assembly and encrypted infra secrets
- `apps/`: homelab-specific app assembly and encrypted app secrets

The Flux dependency order is:

```text
sources → infra → issuers → certificates → apps
              └→ metallb-config
```

The `infra` and `apps` Kustomizations decrypt SOPS resources with the
`flux-system/sops-age` Secret. Restore that Secret before reconciliation when
rebuilding the cluster.
