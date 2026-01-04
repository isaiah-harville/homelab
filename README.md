# Homelab

## Repo Layout

## Commands
Flux sync with main
```
flux reconcile source git flux-system -n flux-system
flux reconcile kustomization flux-system -n flux-system --with-source
```

Kustomization hangs
```
flux get kustomizations -A
kubectl -n flux-system describe kustomization [name]
```

## Repo Layout
clusters/
  homelab/
    kustomization.yaml          # entrypoint for cluster
    flux-system/                # post-bootstrap patches
    infra/                      # infra kustomization
    apps/                       # apps kustomization
infrastructure/
  base/
    namespaces/
    ingress-nginx/
    cert-manager/
    metallb/
    longhorn/
apps/
  base/
    echo-server/
flux/
  image-automation/
  sources/
.sops.yaml

## TODO
- Replace placeholders in `metallb/values.yaml`, `cert-manager/`, and any Helm values.
- Bring back services: add HelmReleases under `apps/base/` or plain Kustomize overlays.
- `flux/image-automation/`
- Add cluster-unique overlays under `apps/overlays/`
- ghcr-creds image pull secrerts consistent
