# Test harness for the CoreOS Omni host

Throwaway QEMU VMs on an Apple Silicon Mac (aarch64, HVF): an FCOS VM built
from the real `omni.bu`, and a Talos VM that joins it over SideroLink. It
never contacts the production host or cluster: it uses a `.test` domain, a
throwaway CA and a throwaway age key.

Needs `brew install qemu butane swtpm sops age gettext` and Docker.

```bash
export WORK=<scratch dir>           # holds keys, disks, ISOs
export TPM_SOCK=/tmp/omni-tpm.sock  # unix socket paths max out at ~104 bytes
age-keygen -o $WORK/test.agekey
# $WORK/secrets.sops.yaml: secrets.example.yaml's keys, encrypted to that key
#   sops -e --age $(age-keygen -y $WORK/test.agekey) \
#     --encrypted-regex '^(data|stringData)$' plain.yaml > $WORK/secrets.sops.yaml
# $WORK/versions.yaml: versions.yaml, optionally pinned older to test omni-sync
FCOS_ISO=<fedora-coreos-live.aarch64.iso> test/build.sh
test/vm.sh install && test/vm.sh start
test/vm.sh ssh sudo omni-health
test/vm.sh omnictl jointoken kernel-args
```

Network boot: with the Omni VM up, generate a menu and serve it where
`PXE_MENU_URL` points (`http://10.0.2.2:8000/boot.ipxe`, next to
`versions.yaml`), let `omni-sync` install it, then boot a blank VM:

```bash
OMNICTL="$PWD/test/vm.sh omnictl" ARCH=arm64 pxe/presets.sh $WORK/serve/boot.ipxe
test/vm.sh ssh sudo omni-sync
test/vm.sh pxe      # fetches ipxe.efi + boot.ipxe from the host's TFTP on :1069
test/vm.sh omnictl get links
```

For the Talos VM, put those kernel args (plus `console=ttyAMA0`) in an
Image Factory schematic's `extraKernelArgs`, download its
`metal-arm64.iso` to `$WORK/talos-join.iso` and run `test/vm.sh talos`.

## What differs from production, and why

- `test/host.env`: `.test` names, `OMNI_LAN_IP=10.0.2.2` (QEMU's gateway,
  which the Talos VM uses to reach the forwarded ports), a test CIDR.
- `overlay.bu`, merged on top of the real config: trusts the throwaway CA,
  pre-seeds a `*.fcos.test` certificate instead of lego's first issuance,
  and holds Zincati until the update test.
- `build.sh` patches `omni.service`. It drops `--machine-api-cert/key` and
  advertises `grpc://10.0.2.2:8090/`, because Talos in maintenance mode
  can't trust a private CA. It also adds an initial Admin service account
  for omnictl.
- The host's 69/udp is forwarded on 1069 (the Mac can't bind 69 without
  root). `vm.sh pxe` fetches the two files from there and lets QEMU's
  DHCP/TFTP serve them to the PXE VM, which runs with `ipv6=off`.
- `test/host.env` sets `PXE_ARCH=arm64`.
- `vm.sh` gives the TPM `ppi=off` (HVF rejects the PPI region's alignment)
  and adds `virtio-rng-pci` (Talos blocks on entropy without it).
