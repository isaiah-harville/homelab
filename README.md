# Homelab

GitOps repo for managing the clusters in my homelab.

## Layout

```
clusters/homelab/   — Flux composition for the k3s cluster
infrastructure/     — Reusable infrastructure building blocks (Longhorn, cert-manager, Traefik, …)
apps/               — Reusable app building blocks
ansible/            — Provision Ubuntu 24 machines as k3s nodes
.devcontainer/      — mono devcontainer (Python/uv, Rust, pnpm)
```

## Clusters

### k3s

Main cluster. Flux reconciles from `clusters/homelab/`.

```bash
flux reconcile source git flux-system -n flux-system
flux get kustomizations -A
```

## Storage (Longhorn)

Distributed block storage across the nodes, configured via Helm
values in `infrastructure/base/longhorn/helmrelease.yaml`:

- `defaultDataPath: /data/longhorn` + `storageReservedPercentageForDefaultDisk: 30`
  — Longhorn auto-creates the disk on each node and reserves 30%. No per-node
  config; provision a node with ansible and its storage appears automatically.
- `defaultReplicaCount: 3` with strict anti-affinity puts one replica on each
  node, so **any single node can fail with no data loss** and volumes stay
  redundant during the outage.

## Devcontainer

The `mono` devcontainer ships Python (uv), Rust, and pnpm
It is published to `ghcr.io/isaiah-harville/homelab/mono:latest`.
