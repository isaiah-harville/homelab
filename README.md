# Homelab

GitOps repo for managing the homelab cluster: a **Talos Linux** cluster managed by
a self-hosted **Omni**, with **Flux** reconciling the k8s layer.

## Layout

```
omni-server/      — Self-hosted Omni Compose stack and runbook
talos/            — Talos image schematic, Omni template, and machine patches
terraform/omni/   — Terraform representation of the Omni cluster
clusters/homelab/ — Flux composition and cluster-specific secrets
infrastructure/   — Reusable cluster services and Flux sources
apps/             — In-repo workloads and external-repository releases
.github/workflows/ — Validation, devcontainer publishing, and Terraform automation
```

See [`CLAUDE.md`](CLAUDE.md) for operational detail.

## Cluster

Flux reconciles from `clusters/homelab/`; provisioning is Talos + Omni (no ansible).

```bash
# k8s layer (Flux)
flux reconcile source git flux-system -n flux-system
flux get kustomizations -A

# machine layer (Omni)
omnictl kubeconfig --cluster homelab     # fetch kubeconfig
omnictl get machines                     # machine inventory
```

Bring-up runbooks: [`omni-server/README.md`](omni-server/README.md) (management
plane) then [`talos/README.md`](talos/README.md) (cluster).

## Storage (Longhorn)

Distributed block storage across the nodes, configured via Helm values in
`infrastructure/base/longhorn/helmrelease.yaml`:

- `defaultDataPath: /var/mnt/longhorn` + `storageReservedPercentageForDefaultDisk: 30`
  — on Talos this is a dedicated disk mounted via `UserVolumeConfig`. Storage nodes
  need both `longhorn-disk.yaml` and `longhorn-storage-node.yaml`.
- `defaultReplicaCount: 3` with strict anti-affinity puts one replica on each
  node, so **any single node can fail with no data loss** and volumes stay
  redundant during the outage.

## Validation

Run the same repository checks used locally before committing:

```bash
uvx pre-commit run --all-files
terraform -chdir=terraform/omni fmt -check -recursive
```

GitHub Actions also lints YAML and renders the cluster Kustomizations.

## Devcontainer

The `mono` devcontainer includes Docker, kubectl/Helm, Talos tooling, Python/uv,
Rust, Node.js, and pnpm.
It is published to `ghcr.io/isaiah-harville/homelab/mono:latest`.
