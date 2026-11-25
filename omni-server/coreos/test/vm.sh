#!/usr/bin/env bash
# QEMU (aarch64, macOS HVF) harness for the Omni CoreOS test VM and a Talos VM.
#
#   WORK=<dir> test/vm.sh install   boot install.iso; exits when the installer reboots
#   WORK=<dir> test/vm.sh start     boot the installed disk (background)
#   WORK=<dir> test/vm.sh stop      power off the Omni VM
#   WORK=<dir> test/vm.sh talos [iso]  boot a Talos VM from a join ISO (background)
#   WORK=<dir> test/vm.sh pxe       boot a blank VM from the network (background)
#   WORK=<dir> test/vm.sh ssh [cmd] ssh core@ the Omni VM
#   WORK=<dir> test/vm.sh omnictl <args>  omnictl run inside the Omni VM
#
# Both VMs use QEMU user networking. The Omni VM's ports are forwarded to
# 127.0.0.1 on the Mac, and the Talos VM reaches them at 10.0.2.2 (its
# gateway, i.e. the Mac): the same path SideroLink takes on the LAN.
set -euo pipefail
: "${WORK:?set WORK to the scratch directory}"
share=$(brew --prefix qemu)/share/qemu
cmd=${1:?command}
# Unix socket paths are limited to ~104 bytes. ppi=off below: the TPM PPI
# region is not 16K-aligned, which HVF on Apple Silicon rejects.
TPM_SOCK=${TPM_SOCK:-$WORK/tpm.sock}
shift

fwd="hostfwd=tcp:127.0.0.1:2222-:22"
for p in 443 5556 8090 8100 2122 10000; do
  off=$((p == 443 ? 8443 : p))
  fwd+=",hostfwd=tcp:127.0.0.1:$off-:$p"
done
fwd+=",hostfwd=udp:127.0.0.1:50180-:50180,hostfwd=udp:127.0.0.1:1069-:69"

firmware() {
  local vars=$1
  # Fresh UEFI variables each boot: entries left by the installer run point
  # at the removed CD-ROM and stop edk2 from falling back to the disk.
  : > "$vars"
  truncate -s 64m "$vars"
  printf '%s\n' -drive "if=pflash,format=raw,readonly=on,file=$share/edk2-aarch64-code.fd" \
    -drive "if=pflash,format=raw,file=$vars"
}

tpm() {
  mkdir -p "$WORK/tpm"
  if ! pgrep -f "swtpm socket --tpmstate dir=$WORK/tpm" > /dev/null; then
    swtpm socket --tpmstate "dir=$WORK/tpm" --ctrl "type=unixio,path=$TPM_SOCK" \
      --tpm2 --daemon --log "file=$WORK/swtpm.log"
    sleep 1
  fi
}

omni_vm() {
  tpm
  [[ -f $WORK/omni.qcow2 ]] || qemu-img create -f qcow2 "$WORK/omni.qcow2" 40G > /dev/null
  # shellcheck disable=SC2046
  qemu-system-aarch64 -machine virt,accel=hvf -cpu host -smp 4 -m 4096 \
    $(firmware "$WORK/omni-vars.fd") \
    -drive "if=virtio,format=qcow2,file=$WORK/omni.qcow2" \
    -netdev "user,id=n0,$fwd" -device virtio-net-pci,netdev=n0 -device virtio-rng-pci \
    -chardev "socket,id=chrtpm,path=$TPM_SOCK" \
    -tpmdev emulator,id=tpm0,chardev=chrtpm -device tpm-tis-device,tpmdev=tpm0,ppi=off \
    -display none "$@"
}

case $cmd in
  install)
    omni_vm -no-reboot -serial "file:$WORK/install-console.log" \
      -device virtio-scsi-pci -drive "if=none,id=cd,media=cdrom,readonly=on,file=$WORK/install.iso" \
      -device scsi-cd,drive=cd
    ;;
  start)
    omni_vm -serial "file:$WORK/omni-console.log" -pidfile "$WORK/omni.pid" -daemonize
    ;;
  stop)
    ssh_opts=(-p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
    ssh "${ssh_opts[@]}" core@127.0.0.1 sudo systemctl poweroff || true
    while [[ -f $WORK/omni.pid ]] && kill -0 "$(cat "$WORK/omni.pid")" 2> /dev/null; do sleep 2; done
    ;;
  talos)
    # A UEFI-booted ISO from Image Factory with the join kernel args baked in
    # (as Omni's own install media does). Direct kernel boot has no firmware,
    # so no SMBIOS UUID, and Talos never registers with Omni.
    [[ -f $WORK/talos.qcow2 ]] || qemu-img create -f qcow2 "$WORK/talos.qcow2" 10G > /dev/null
    # shellcheck disable=SC2046
    qemu-system-aarch64 -machine virt,accel=hvf -cpu host -smp 2 -m 2048 \
      $(firmware "$WORK/talos-vars.fd") \
      -uuid 7a1c0d2e-0000-4000-8000-0000000000a1 \
      -drive "if=virtio,format=qcow2,file=$WORK/talos.qcow2" \
      -device virtio-scsi-pci -drive "if=none,id=cd,media=cdrom,readonly=on,file=${1:-$WORK/talos-join.iso}" \
      -device scsi-cd,drive=cd \
      -netdev user,id=n0 -device virtio-net-pci,netdev=n0 -device virtio-rng-pci \
      -display none -serial "file:$WORK/talos-console.log" -pidfile "$WORK/talos.pid" -daemonize
    ;;
  omnictl)
    # omnictl inside the Omni VM, where the .test names resolve (Omni needs
    # SNI) and the test service account key lives.
    exec "$0" ssh "set -e; v=\$(sed -nE 's/^OMNI_IMAGE=.*:(v[0-9.]+).*/\1/p' /etc/omni/images.env)
      [ -x /var/tmp/omnictl-\$v ] || curl -fsSLo /var/tmp/omnictl-\$v https://github.com/siderolabs/omni/releases/download/\$v/omnictl-linux-arm64
      chmod +x /var/tmp/omnictl-\$v
      OMNI_ENDPOINT=https://\$(sed -n 's/^OMNI_HOST=//p' /etc/omni/host.env)/ \
      OMNI_SERVICE_ACCOUNT_KEY=\$(sudo cat /var/lib/omni/data/initial-sa.key) /var/tmp/omnictl-\$v $*"
    ;;
  pxe)
    # A blank UEFI machine that network-boots. The Mac can't bind 69/udp
    # without root, so the Omni VM's TFTP is forwarded on 1069: fetch
    # ipxe.efi and boot.ipxe from it with a real TFTP client, then let QEMU's
    # DHCP/TFTP hand exactly those files to the VM (next-server 10.0.2.2).
    # ipv6=off: otherwise iPXE prefers the factory's AAAA record, and the
    # Mac has no IPv6 route out.
    mkdir -p "$WORK/tftp-mirror"
    for f in ipxe.efi boot.ipxe; do
      curl -fsS -o "$WORK/tftp-mirror/$f" "tftp://127.0.0.1:1069/$f"
    done
    qemu-img create -f qcow2 "$WORK/pxe.qcow2" 10G > /dev/null
    # shellcheck disable=SC2046
    qemu-system-aarch64 -machine virt,accel=hvf -cpu host -smp 2 -m 2048 \
      $(firmware "$WORK/pxe-vars.fd") \
      -uuid 7a1c0d2e-0000-4000-8000-0000000000b2 \
      -drive "if=virtio,format=qcow2,file=$WORK/pxe.qcow2" \
      -netdev "user,id=n0,ipv6=off,tftp=$WORK/tftp-mirror,bootfile=ipxe.efi" \
      -device virtio-net-pci,netdev=n0 -device virtio-rng-pci \
      -display none -serial "file:$WORK/pxe-console.log" -pidfile "$WORK/pxe.pid" -daemonize
    ;;
  ssh)
    exec ssh -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
      core@127.0.0.1 "$@"
    ;;
  *)
    echo "unknown command $cmd" >&2
    exit 2
    ;;
esac
