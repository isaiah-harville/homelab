#!/usr/bin/env bash
# (Re)create the Omni installation-media presets for network boot and write
# their Image Factory PXE URLs into boot.ipxe. Run it with omnictl pointed at
# the Omni this host serves, after a Talos or extension change, and commit
# boot.ipxe; omni-sync installs it on the host.
#
#   pxe/presets.sh [output]        default: pxe/boot.ipxe
#
# TALOS_VERSION defaults to talos_version in terraform/omni/locals.tf; the
# extensions mirror base_extensions and gpu_extensions there (Talos is
# immutable, so the NVIDIA driver and toolkit come as system extensions; the
# GPU operator runs on top with its driver and toolkit disabled). The URLs carry
# Omni's join token inside the schematic (as any Omni install media does):
# treat boot.ipxe as config, not a secret.
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
out=${1:-$here/boot.ipxe}
omnictl=${OMNICTL:-omnictl}
locals="$here/../../../terraform/omni/locals.tf"
TALOS_VERSION=${TALOS_VERSION:-$(sed -nE 's/^[[:space:]]*talos_version[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$locals")}
: "${TALOS_VERSION:?set TALOS_VERSION}"
ARCH=${ARCH:-amd64}

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

sed -E -e "s|^set talos-url .*|set talos-url $talos|" -e "s|^set nvidia-url .*|set nvidia-url $nvidia|" \
  "$here/boot.ipxe" > "$out.tmp"
mv "$out.tmp" "$out"
echo "wrote $out (Talos $TALOS_VERSION)"
