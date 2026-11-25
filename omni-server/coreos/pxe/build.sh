#!/usr/bin/env bash
# Build ipxe.efi on a workstation, the same way the Omni host does, to test
# or inspect it.
#
#   pxe/build.sh <x86_64|arm64> <default-server-ip> <output.efi>
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
image=$(sed -nE 's/^[[:space:]]*ipxe-build:[[:space:]]*([^[:space:]#]+).*/\1/p' "$here/../versions.yaml")
out=${3:?usage: pxe/build.sh <x86_64|arm64> <default-server-ip> <output.efi>}
mkdir -p "$(dirname "$out")"
out_dir=$(cd "$(dirname "$out")" && pwd)
docker run --rm -v "$here:/pxe:ro" -v "$out_dir:/out" "$image" \
  sh /pxe/build-ipxe.sh "$1" "$2" /pxe/embed.ipxe "/out/$(basename "$out")"
