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

## Devcontainer

The `mono` devcontainer ships Python (uv), Rust, and pnpm
It is published to `ghcr.io/isaiah-harville/homelab/mono:latest`.
