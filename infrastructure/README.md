# Infrastructure Layout

`infrastructure/` is the platform layer, laid out like `apps/`: one folder per
namespace, one folder per component inside it.

```
infrastructure/<namespace>/
  kustomization.yaml   # namespace.yaml + each <component>/ks.yaml
  namespace.yaml       # Pod Security labels live here
  <component>/
    ks.yaml            # the component's own Flux Kustomization
    app/               # HelmRelease or manifests, kustomization.yaml, *.sops.yaml
```

The root `infra` Kustomization (`clusters/homelab/infra`) applies only the
namespaces and the per-component Kustomizations, so one unhealthy component
no longer holds up changes to the rest. Ordering that matters is expressed with
`dependsOn` in each `ks.yaml` (for example `issuers` waits for `cert-manager`,
`metallb-config` for `metallb`).

Unlike apps, infrastructure components set their namespaces in their own
manifests rather than with `targetNamespace`, because several span more than
one namespace or are cluster-scoped.

`sources/` is not a component: it holds the Flux `HelmRepository` and
`OCIRepository` objects, reconciled by the `sources` Kustomization before
anything else.

Several components ship CRDs (Longhorn, CloudNativePG, cert-manager, the
RabbitMQ operator, the Barman Cloud plugin). Removing or renaming one of these
Kustomizations prunes its CRDs and with them every custom resource of that
kind, so move them the way `docs/operations/flux-layout.md` describes.

HelmReleases use `CreateReplace` for CRDs during both install and upgrade. This
keeps chart-owned CRDs current under Flux; Helm's normal upgrade behavior skips
files in a chart's `crds/` directory.
