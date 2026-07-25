# Generated reference

Reference pages in this section are generated from the repository's YAML during
every MkDocs build. Do not edit the generated pages directly; change the
manifests or `scripts/generate_reference.py`.

The generator currently documents:

- Flux `HelmRelease` chart, version, and source references
- Flux artifact sources
- Flux `Kustomization` paths and dependencies

`helm-docs` is not enabled because this repository consumes external charts and
does not contain any `Chart.yaml` files. If local charts are added later,
`helm-docs` will become useful for documenting their `values.yaml` interfaces.
