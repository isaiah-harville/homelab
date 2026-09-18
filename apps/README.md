# Apps Layout

One folder per namespace, one folder per app inside it:

```
apps/<namespace>/
  kustomization.yaml   # namespace.yaml + each <app>/ks.yaml
  namespace.yaml
  <app>/
    ks.yaml            # the app's own Flux Kustomization
    app/               # manifests, kustomization.yaml, *.sops.yaml
```

Each `ks.yaml` is a Flux `Kustomization` in `flux-system` that applies `app/`
into its `targetNamespace` and reports its own health. A namespace folder is
deployed once it is listed in `clusters/homelab/apps/kustomization.yaml`.

Apps sourced from another Git repository (`swing-thoughts`) keep a
`GitRepository`, an `<app>-upstream` Flux `Kustomization` and their Ingress in
`app/`. `openvitae` is similar but installs a Helm chart from its repository.
