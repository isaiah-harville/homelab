# Architecture overview

The homelab has two declarative management layers:

```text
Terraform + Omni ──> Talos machines ──> Kubernetes API
                                            │
Git repository ──> Flux source ──> Kustomizations
                                            │
                     infrastructure + applications
```

## Machine layer

Omni manages Talos machine enrollment, configuration, upgrades, and lifecycle.
Terraform declares Omni resources and shares the Talos patches stored under
`talos/omni/patches/`. The cluster template remains a manual recovery path.

This layer is responsible for:

- Talos and Kubernetes versions
- machine assignments and installation targets
- Kubernetes API availability
- storage-device preparation
- node lifecycle operations

## Kubernetes layer

Flux watches this repository and reconciles the Kubernetes resources rooted at
`clusters/homelab/`. Base infrastructure and applications remain reusable;
the cluster directory chooses which pieces are active.

Flux Operator manages controller lifecycle and provides the status UI and
reporting APIs. During the zero-downtime ownership migration, the declared
`FluxInstance` uses the supported `2.8.x` distribution and matches the CLI
bootstrap's components and sync settings; both sets of manifests remain in Git.
The generated bootstrap manifests are removed only after the instance is Ready
and the root Kustomization is no longer reported as Flux-managed.

This layer is responsible for:

- controllers and shared platform services
- ingress, certificates, storage, and monitoring
- application releases
- encrypted Kubernetes secrets

## Management services

Omni runs outside the Kubernetes cluster so machine management and recovery do
not depend on the cluster being healthy. GitHub Actions uses an in-cluster
runner for workflows that need access to LAN-only services.

## Ownership boundaries

| Concern | Source of truth | Reconciler |
| --- | --- | --- |
| Talos machine configuration | `terraform/omni/` and `talos/omni/patches/` | Terraform and Omni |
| Kubernetes composition | `clusters/homelab/` | Flux |
| Reusable platform services | `infrastructure/base/` | Flux |
| Application definitions | `apps/` | Flux |
| Secret ciphertext | SOPS-encrypted manifests | Flux with SOPS |
| Terraform state | Kubernetes backend | Terraform |
