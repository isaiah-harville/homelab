#!/usr/bin/env bash
# (Re)create the Omni installation-media presets for network boot, fill
# their Image Factory PXE URLs into the menu template (pxe/boot.ipxe.tmpl) and
# install the result on the Omni host's TFTP root. Run it with omnictl pointed
# at that Omni. Talos upgrades don't need a re-run: the network image only
# reaches maintenance mode, and Omni installs the cluster's Talos version
# when a machine joins. Re-run it for a newer network image (new hardware,
# extension changes). TFTP serves the new menu at once; it lives on
# omni-data, so a reinstall keeps it.
#
#   pxe/presets.sh                 install on the Omni host (OMNI_LAN_IP)
#   pxe/presets.sh --output FILE   write the menu to FILE instead
#
# The filled-in menu never goes into git: anyone can read a schematic at
# factory.talos.dev/schematics/<id>, and Omni's schematics embed its join
# token. The committed pxe/boot.ipxe.tmpl is only the template. (It isn't
# named boot.ipxe so that hosts installed before this change, whose
# omni-sync fetched pxe/boot.ipxe from main, find nothing there and keep
# the menu this script installs.)
#
# TALOS_VERSION defaults to talos_version in terraform/omni/locals.tf; the
# extensions mirror base_extensions and gpu_extensions there (Talos is
# immutable, so the NVIDIA driver and toolkit come as system extensions; the
# GPU operator runs on top with its driver and toolkit disabled).
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
omnictl=${OMNICTL:-omnictl}
locals="$here/../../../terraform/omni/locals.tf"
TALOS_VERSION=${TALOS_VERSION:-$(sed -nE 's/^[[:space:]]*talos_version[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$locals")}
: "${TALOS_VERSION:?set TALOS_VERSION}"
ARCH=${ARCH:-amd64}
host=${OMNI_SSH:-core@$(sed -nE 's/^OMNI_LAN_IP=(.*)/\1/p' "$here/../host.env")}
output=
if [[ ${1:-} == --output ]]; then
  output=${2:?usage: pxe/presets.sh [--output FILE]}
fi

base=(--extensions siderolabs/iscsi-tools --extensions siderolabs/util-linux-tools)
gpu=("${base[@]}" --extensions siderolabs/nonfree-kmod-nvidia-production
  --extensions siderolabs/nvidia-container-toolkit-production)

url_for() {
  local name=$1
  shift
  # Presets are this script's own; recreate so a changed version or
  # extension list takes effect.
  if $omnictl media preset list 2> /dev/null | awk 'NR > 1 {print $1}' | grep -qx "$name"; then
    $omnictl media preset delete "$name" > /dev/null
  fi
  $omnictl media preset create "$name" --arch "$ARCH" --talos-version "$TALOS_VERSION" "$@" > /dev/null
  $omnictl media download "$name" --format pxe 2> /dev/null |
    grep -Eo 'https://[^[:space:]]+/metal-[a-z0-9]+' | tail -n1 |
    # The menu picks the architecture at boot time.
    sed -E 's|/metal-[a-z0-9]+$|/metal-${arch}|'
}

talos=$(url_for homelab-talos "${base[@]}")
nvidia=$(url_for homelab-talos-nvidia "${gpu[@]}")
[[ $talos == https://* && $nvidia == https://* ]] || { echo "presets.sh: no PXE URL from omnictl" >&2; exit 1; }

menu() {
  sed -E -e "s|^set talos-url .*|set talos-url $talos|" -e "s|^set nvidia-url .*|set nvidia-url $nvidia|" \
    "$here/boot.ipxe.tmpl"
}

if [[ -n $output ]]; then
  umask 077
  menu > "$output"
  echo "wrote $output (Talos $TALOS_VERSION); it holds Omni's join token, keep it out of git"
else
  menu | ssh "$host" 'sudo sh -c "cat > /var/lib/omni/tftp/boot.ipxe.tmp &&
    chmod 0644 /var/lib/omni/tftp/boot.ipxe.tmp &&
    mv /var/lib/omni/tftp/boot.ipxe.tmp /var/lib/omni/tftp/boot.ipxe"'
  echo "installed the menu on $host (Talos $TALOS_VERSION)"
fi
