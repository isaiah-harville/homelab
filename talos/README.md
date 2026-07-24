# Talos cluster (via Omni)

Machine image + Omni cluster template for the homelab cluster. Replaces the old
`ansible/` provisioning entirely. The management plane (Omni) is set up first —
see [`../omni-server/`](../omni-server/).

## Layout

```
image/schematic.yaml        Image Factory schematic (Longhorn extensions)
omni/cluster-template.yaml   Omni cluster template (topology + version pins)
omni/patches/                Talos machine-config patches
  install-disk.yaml            OS install target
  allow-scheduling.yaml        run workloads on control-plane nodes
  controlplane-vip.yaml        floating API VIP 10.1.10.9 (replaces kube-vip)
  longhorn-disk.yaml           dedicated Longhorn disk (UserVolumeConfig) + mount
```

## Nodes

| Role          | Machines                                  |
|---------------|-------------------------------------------|
| Control plane | precision-1, precision-2, latitude-01     |
| Workers       | dl380, thinkcentre-01                     |

GPU boxes (`harvi-desktop` WSL, `spark-a97a` DGX) are **not** cluster members.

## Bring-up

### 1. Build the installer image

```bash
curl -X POST --data-binary @image/schematic.yaml \
  https://factory.talos.dev/schematics
# → returns a schematic id; build the matching ISO/metal image, e.g.:
#   https://factory.talos.dev/image/<id>/<talos-version>/metal-amd64.iso
```

Register the same two extensions in Omni (cluster machine config / Extensions)
so Talos upgrades keep them.

### 2. Boot each node → it enrolls in Omni

Boot all 5 nodes off the image (USB/ISO/PXE). With SideroLink configured
(`../omni-server`), each dials home over WireGuard and appears in Omni.

```bash
omnictl get machines        # copy the UUIDs
```

### 3. Fill in the template + confirm disks

- Paste each machine UUID into `omni/cluster-template.yaml` (the `<PLACEHOLDER>`s).
- **Confirm per-node disk layout** (`talosctl get disks` once enrolled):
  - `install-disk.yaml` must select the OS disk.
  - `longhorn-disk.yaml` claims a *separate* non-system disk. Single-NVMe laptops
    have none — see the caveat in that file and adjust their machine class.

### 4. Create the cluster

```bash
omnictl cluster template validate -f omni/cluster-template.yaml
omnictl cluster template sync     -f omni/cluster-template.yaml
```

Omni provisions etcd on the 3 laptops, brings up the VIP `10.1.10.9`, and k8s.

### 5. Pull kubeconfig + sanity-check

```bash
omnictl kubeconfig --cluster homelab
kubectl get nodes                       # all 5 Ready
kubectl get pods -A                      # core components healthy
curl -k https://10.1.10.9:6443/version   # VIP responds
```

Then bootstrap Flux onto the cluster — see the repo root `CLAUDE.md` / the
rebuild plan (Phase 5).

## Day-2

Talos + k8s upgrades are driven from Omni (rolling, one node at a time). No
`talosctl upgrade` by hand, no kured, no medik8s — Omni owns node lifecycle and
health. To add a node: boot it off the image, add its UUID to the template,
`sync`.
