# Homelab

GitOps repo for managing the homelab cluster: a **Talos Linux** cluster managed by
a self-hosted **Omni**, with **Flux** reconciling the k8s layer.

## Layout

```
omni-server/   — Self-hosted Omni (management plane) — docker-compose + runbook
talos/         — Talos image schematic + Omni cluster template + machine-config patches
clusters/homelab/ — Flux composition for the cluster
infrastructure/   — Reusable infrastructure building blocks (Longhorn, cert-manager, Traefik, …)
apps/             — Reusable app building blocks
.devcontainer/    — mono devcontainer (Python/uv, Rust, pnpm)
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
  — on Talos this is a dedicated disk mounted via `UserVolumeConfig`
  (`talos/omni/patches/longhorn-disk.yaml`); Longhorn reserves 30%. Enroll a node
  with that patch and its storage appears.
- `defaultReplicaCount: 3` with strict anti-affinity puts one replica on each
  node, so **any single node can fail with no data loss** and volumes stay
  redundant during the outage.

## Devcontainer

The `mono` devcontainer ships Python (uv), Rust, and pnpm.
It is published to `ghcr.io/isaiah-harville/homelab/mono:latest`.
