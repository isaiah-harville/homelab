#!/bin/sh
# Build iPXE with the embedded script. Runs inside the pinned Debian image
# (IPXE_BUILD_IMAGE in versions.yaml), both on the Omni host
# (pxe-ipxe-build.service) and on a workstation (pxe/build.sh).
#
#   build-ipxe.sh <x86_64|arm64> <default-server-ip> <embed.ipxe> <output.efi>
#
# snponly.efi drives the NIC through the firmware's own UEFI driver: it is the
# usual build to chainload from UEFI PXE, and a quarter the size of ipxe.efi.
set -eu
arch=$1 server=$2 embed=$3 out=$4

# iPXE v2.0.0 (2026-03-06). Bump deliberately: this is what every
# network-booted machine runs first.
IPXE_COMMIT=12798ec29aa8a64d8675c4378b99f5fe28447afb

case $arch in
  x86_64) target=bin-x86_64-efi/snponly.efi gnu=x86_64-linux-gnu ;;
  arm64) target=bin-arm64-efi/snponly.efi gnu=aarch64-linux-gnu ;;
  *) echo "build-ipxe.sh: unknown arch $arch" >&2; exit 2 ;;
esac

# Native gcc, plus a cross compiler when the target isn't this machine.
native=$(dpkg --print-architecture)
cross=
case "$native:$arch" in
  amd64:x86_64 | arm64:arm64) pkgs= ;;
  *) pkgs=gcc-$(echo "$gnu" | tr _ -) cross=$gnu- ;;
esac
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -qq -y --no-install-recommends \
  ca-certificates git make gcc libc6-dev binutils perl liblzma-dev $pkgs > /dev/null

git init -q /ipxe
cd /ipxe
git fetch -q --depth 1 https://github.com/ipxe/ipxe.git "$IPXE_COMMIT"
git checkout -q FETCH_HEAD
# HTTPS is on by default for EFI in v2.0.0; set it explicitly so an upstream
# change can't silently drop it. The image factory serves HTTPS only.
printf '#define DOWNLOAD_PROTO_HTTPS\n#define DOWNLOAD_PROTO_TFTP\n' > src/config/local/general.h

sed "s|@DEFAULT_SERVER@|$server|" "$embed" > /tmp/embed.ipxe

# Trust the Mozilla roots from this (pinned) Debian image's ca-certificates,
# embedded so iPXE can complete chains the server doesn't send in full.
# iPXE's default trust is only its own root, reaching public CAs through
# cross-signed certificates from ca.ipxe.org over plain HTTP, and that
# rejected the Image Factory's chain (ZeroSSL -> Sectigo R46 -> USERTrust).
roots=$(ls /usr/share/ca-certificates/mozilla/*.crt | tr '\n' ',' | sed 's/,$//')
make -s -C src -j"$(nproc)" CROSS="$cross" EMBED=/tmp/embed.ipxe \
  TRUST="$roots" CERT="$roots" "$target" > /dev/null
cp "src/$target" "$out"
echo "built $out: iPXE $IPXE_COMMIT, $arch, default server $server"
