# Homelab Layout

`clusters/homelab/` is the composition layer for the main homelab Talos cluster.

Folders:
- `flux-system/`: the `FluxInstance` and the three root Flux Kustomizations
  (`sources`, `infra`, `apps`)
- `infra/`: selects the `infrastructure/<namespace>` folders
- `apps/`: selects the `apps/<namespace>` folders, plus secrets shared across
  namespaces (`secrets/`, copied where needed by reflector)

The roots only create namespaces and per-component Flux Kustomizations; each
component then reconciles and health-checks on its own. The order on a fresh
cluster is:

```text
sources → infra components (dependsOn among themselves, e.g.
          cert-manager → issuers → certificates, metallb → metallb-config)
       → apps (waits for certificates, storage and the operators apps use)
```

SOPS-encrypted resources are decrypted with the `flux-system/sops-age` Secret.
Restore that Secret before reconciliation when rebuilding the cluster.
