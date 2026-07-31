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

Flux Operator observes the CLI-bootstrapped Flux installation and provides its
status UI and reporting APIs. The checked-in Flux controller manifests remain
the source of truth; there is no operator-managed `FluxInstance`. Operator
ownership is the preferred eventual state, but migration must be staged so the
existing reconciler is not pruned before the operator has taken control.

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
