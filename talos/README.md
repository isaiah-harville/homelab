# Talos cluster (via Omni)

Machine image + Omni cluster template for the homelab cluster. The management
plane (Omni) is set up first — see
[`../omni-server/README.md`](../omni-server/README.md).

## Layout

```
image/schematic.yaml        Image Factory schematic (Longhorn extensions)
omni/cluster-template.yaml   Omni cluster definition + version pins
omni/patches/                Talos machine-config patches
  install-*.yaml               per-machine OS disk selectors
  allow-scheduling.yaml        run workloads on control-plane nodes
  controlplane-vip.yaml        floating Kubernetes API VIP
  kubernetes-oidc.yaml         trust Authentik OIDC tokens for Kubernetes RBAC
  longhorn-disk.yaml           dedicated Longhorn disk (UserVolumeConfig) + mount
  longhorn-root-disk.yaml      mount Longhorn path on a shared system disk
  longhorn-storage-node.yaml   label nodes eligible for Longhorn disk creation
  nvidia-gpu.yaml              load the NVIDIA kernel modules on GPU machines
```

## Bring-up

### 1. Build the installer image

```bash
curl -X POST --data-binary @image/schematic.yaml \
  https://factory.talos.dev/schematics
# → returns a schematic id; build the matching ISO/metal image, e.g.:
#   https://factory.talos.dev/image/<id>/<talos-version>/metal-amd64.iso
```

Extensions are applied through Terraform, like the rest of the machine layer:
`omni_machine_extensions` in `../terraform/omni/extensions.tf` sets a
cluster-wide base list and narrows it per machine for the GPU nodes. Omni
reconciles a change as an upgrade, so the machine reboots onto a schematic
carrying them and later Talos upgrades keep them.

`omni/cluster-template.yaml` repeats the same list per machine for the manual
fallback path; keep the two in step.

### 2. Boot each node → it enrolls in Omni

Boot each node from the image (USB/ISO/PXE). With SideroLink configured
(`../omni-server`), each dials home over WireGuard and appears in Omni.

```bash
omnictl get machines        # copy the UUIDs
```

### 3. Confirm machine assignments and disks

- Confirm the enrolled UUIDs match `omni/cluster-template.yaml`.
- Inspect each machine's disks in Omni or with `talosctl get disks`.
- Verify its selected `install-*.yaml` patch targets the intended OS disk.
- Apply both `longhorn-disk.yaml` and `longhorn-storage-node.yaml` only to machines
  with a dedicated spare disk.
- On an intentionally selected single-disk storage node, apply
  `longhorn-root-disk.yaml` and `longhorn-storage-node.yaml` instead. Longhorn's
  reserved-space setting protects capacity needed by Talos and workloads.
- Apply `nvidia-gpu.yaml` — plus the two NVIDIA extensions — only to machines
  with a discrete NVIDIA GPU (see "GPU nodes" below). The patch only modprobes
  the modules; without the extensions that ship them it does nothing.
- Keep the same UUIDs and patch mapping in `../terraform/omni/locals.tf`.

### 4. Create or update the cluster

```bash
omnictl cluster template validate -f omni/cluster-template.yaml
omnictl cluster template sync     -f omni/cluster-template.yaml
```

Omni provisions etcd, brings up the Kubernetes API VIP, and starts Kubernetes.
The template is the manual fallback for `terraform/omni/`; do not make machine
assignment changes through both paths independently.

### 5. Pull kubeconfig + sanity-check

```bash
omnictl kubeconfig --cluster homelab
kubectl get nodes                       # all expected nodes Ready
kubectl get pods -A                      # core components healthy
kubectl cluster-info                     # API responds
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

Talos + k8s upgrades are driven from Omni (rolling, one node at a time), which
owns node lifecycle and health. To add a node: boot it off the image, add its
UUID to the template, update `terraform/omni/locals.tf`, and apply through the
chosen control path.

## GPU nodes

Two machines have a discrete NVIDIA GPU:

| Machine UUID | Node | GPU |
| --- | --- | --- |
| `4c4c4544-0030-5910-805a-c6c04f503133` | talos-h5j-x2r | Quadro T1000 Mobile (Turing) |
| `4c4c4544-0039-4210-8046-b8c04f314a33` | talos-6t5-q1d | RTX A2000 Mobile (Ampere) |

Re-check after any hardware change:

```bash
talosctl get pcidevices | grep -i nvidia
```

Talos is immutable, so the driver cannot be compiled on the node. Each GPU
machine instead gets:

- `siderolabs/nonfree-kmod-nvidia-production` — proprietary kernel modules,
  built per Talos release (`<driver>-<talos-version>`).
- `siderolabs/nvidia-container-toolkit-production` — the container runtime
  bits, versioned `<driver>-<toolkit-version>`.
- `patches/nvidia-gpu.yaml` — loads the modules at boot.

Both extensions must be bumped together, and both are pinned to the Talos
version: **upgrading Talos requires a matching extension set**, or the modules
fail to load. The `-lts` variants are the fallback if the production driver
branch ever drops one of these GPUs.

The Kubernetes half is the NVIDIA GPU operator, reconciled by Flux from
`../infrastructure/base/nvidia-gpu-operator/` with the driver and toolkit
containers disabled. Node Feature Discovery labels the GPU machines, so the
operands place themselves and no node labelling is needed here.

Verify:

```bash
talosctl -n <gpu-node-ip> read /proc/driver/nvidia/version
kubectl get nodes -o custom-columns=NAME:.metadata.name,GPU:.status.allocatable.'nvidia\.com/gpu'
```
