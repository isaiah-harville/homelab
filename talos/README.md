# Talos cluster (via Omni)

Machine image + Omni cluster template for the homelab cluster. Replaces the old
`ansible/` provisioning entirely. The management plane (Omni) is set up first —
see [`../omni-server/`](../omni-server/).

## Layout

```
image/schematic.yaml        Image Factory schematic (Longhorn extensions)
omni/cluster-template.yaml   Omni cluster template (topology + version pins)
omni/patches/                Talos machine-config patches
  install-*.yaml               per-machine OS disk selectors
  allow-scheduling.yaml        run workloads on control-plane nodes
  controlplane-vip.yaml        floating API VIP 10.1.10.9 (replaces kube-vip)
  longhorn-disk.yaml           dedicated Longhorn disk (UserVolumeConfig) + mount
  longhorn-storage-node.yaml   label nodes eligible for Longhorn disk creation
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

### 3. Confirm topology and disks

- Confirm the enrolled UUIDs match `omni/cluster-template.yaml`.
- Inspect each machine's disks in Omni or with `talosctl get disks`.
- Verify its selected `install-*.yaml` patch targets the intended OS disk.
- Apply both `longhorn-disk.yaml` and `longhorn-storage-node.yaml` only to machines
  with a dedicated spare disk.
- Keep the same UUIDs and patch mapping in `../terraform/omni/locals.tf`.

### 4. Create or update the cluster

```bash
omnictl cluster template validate -f omni/cluster-template.yaml
omnictl cluster template sync     -f omni/cluster-template.yaml
```

Omni provisions etcd on the 3 laptops, brings up the VIP `10.1.10.9`, and k8s.
The template is the manual fallback for `terraform/omni/`; do not make topology
changes through both paths independently.

### 5. Pull kubeconfig + sanity-check

```bash
omnictl kubeconfig --cluster homelab
kubectl get nodes                       # all 5 Ready
kubectl get pods -A                      # core components healthy
curl -k https://10.1.10.9:6443/version   # VIP responds
```

### 6. Bootstrap Flux and restore SOPS

For a fresh cluster:

```bash
flux bootstrap github \
  --owner=isaiah-harville \
  --repository=homelab \
  --branch=main \
  --path=clusters/homelab \
  --personal

kubectl -n flux-system create secret generic sops-age \
  --from-file=age.agekey=/secure/path/age.agekey
```

The age identity must match the recipient in `../.sops.yaml`. Restore it before
the `infra` and `apps` Kustomizations reconcile. Keep an encrypted copy outside
the cluster; the private identity is intentionally not stored in this repository.

```bash
flux reconcile source git flux-system -n flux-system
flux get kustomizations -A
```

## Day-2

Talos + k8s upgrades are driven from Omni (rolling, one node at a time). No
`talosctl upgrade` by hand, no kured, no medik8s — Omni owns node lifecycle and
health. To add a node: boot it off the image, add its UUID to the template,
update `terraform/omni/locals.tf`, and apply through the chosen control path.
