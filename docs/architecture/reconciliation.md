# Reconciliation model

Changes should flow through the repository and its reconcilers. Direct changes
to the cluster are useful for inspection and emergency recovery, but they are
not durable configuration.

## Flux ordering

The cluster-level Flux objects define this dependency chain:

```text
sources → infrastructure ─┬→ issuers → certificates → applications
                          ├→ load-balancer configuration
                          └──────────────────────────────↗
```

- Sources must exist before Helm releases can resolve charts.
- Infrastructure installs controllers and shared services.
- Issuers and certificates depend on cert-manager.
- Applications wait for their infrastructure and TLS prerequisites.

The [generated reconciliation reference](../reference/flux-kustomizations.md)
shows the paths and `dependsOn` relationships currently declared in the
manifests.

## Change paths

| Change | Edit | Apply path |
| --- | --- | --- |
| Application configuration | `apps/` or its external repository | Flux |
| Shared service | `infrastructure/base/` | Flux |
| Cluster selection or patch | `clusters/homelab/` | Flux |
| Machine configuration | `talos/omni/patches/` | Terraform and Omni |
| Machine assignment or version | `terraform/omni/` | Terraform and Omni |

## Verification

```bash
flux get sources all -A
flux get kustomizations -A
flux get helmreleases -A
kubectl get nodes
kubectl get pods -A
```

Start with the owning reconciler. A workload symptom often originates in a
failed source, dependency, or controller reconciliation earlier in the chain.
