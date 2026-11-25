#!/usr/bin/env bash
# Render the Omni host's Ignition config: substitute host.env and
# versions.yaml into omni.bu and files/, decrypt secrets.sops.yaml into
# build/secrets/, then `butane --strict`. Output: $OUT/omni.ign (contains
# secrets; build/ is gitignored).
#
# Overrides (for test hosts): HOST_ENV, SECRETS, VERSIONS, OUT, PXE_MENU
# (default pxe/boot.ipxe), SSH_AUTHORIZED_KEYS (a public key file; default
# ~/.ssh/id_ed25519.pub).
set -euo pipefail
cd "$(dirname "$0")"

HOST_ENV=${HOST_ENV:-host.env}
SECRETS=${SECRETS:-secrets.sops.yaml}
VERSIONS=${VERSIONS:-versions.yaml}
OUT=${OUT:-build}
SSH_AUTHORIZED_KEYS=${SSH_AUTHORIZED_KEYS:-$HOME/.ssh/id_ed25519.pub}
PXE_MENU=${PXE_MENU:-pxe/boot.ipxe}

for tool in butane envsubst sops; do
  command -v "$tool" > /dev/null || { echo "render.sh: $tool is required" >&2; exit 1; }
done
[[ -f $SECRETS ]] || { echo "render.sh: $SECRETS not found (see secrets.example.yaml)" >&2; exit 1; }

# host.env values may contain spaces, so read it line by line instead of
# sourcing it.
vars=()
while IFS='=' read -r k v; do
  [[ $k =~ ^[A-Z_][A-Z0-9_]*$ ]] || continue
  export "$k=$v"
  vars+=("$k")
done < "$HOST_ENV"

image() { sed -nE "s/^[[:space:]]*$1:[[:space:]]*([^[:space:]#]+).*/\1/p" "$VERSIONS" | head -n1; }
export OMNI_IMAGE DEX_IMAGE LEGO_IMAGE TOOLS_IMAGE IPXE_BUILD_IMAGE
OMNI_IMAGE=$(image omni)
DEX_IMAGE=$(image dex)
LEGO_IMAGE=$(image lego)
TOOLS_IMAGE=$(image tools)
IPXE_BUILD_IMAGE=$(image ipxe-build)
image_vars=(OMNI_IMAGE DEX_IMAGE LEGO_IMAGE TOOLS_IMAGE IPXE_BUILD_IMAGE)
for v in "${vars[@]}" "${image_vars[@]}"; do
  [[ -n ${!v} ]] || { echo "render.sh: $v is empty" >&2; exit 1; }
done
# Only these names are substituted, so shell variables in files/ survive.
# Image refs go only into images.env: the units
# keep ${OMNI_IMAGE} etc. for systemd to expand from images.env, which
# omni-sync rewrites.
shell_format=$(printf '${%s} ' "${vars[@]}")
image_format=$(printf '${%s} ' "${vars[@]}" "${image_vars[@]}")

mkdir -p "$OUT/secrets"
chmod 700 "$OUT" "$OUT/secrets"

# Scripts are copied verbatim; everything else in files/ is a template.
while IFS= read -r -d '' f; do
  mkdir -p "$OUT/$(dirname "$f")"
  if [[ $f == files/bin/* ]]; then
    cp -p "$f" "$OUT/$f"
  elif [[ $f == files/etc/images.env ]]; then
    envsubst "$image_format" < "$f" > "$OUT/$f"
  else
    envsubst "$shell_format" < "$f" > "$OUT/$f"
  fi
done < <(find files -type f -print0)
envsubst "$shell_format" < omni.bu > "$OUT/omni.bu"
grep -E '^[A-Z_][A-Z0-9_]*=' "$HOST_ENV" > "$OUT/host.env"
cp "$SSH_AUTHORIZED_KEYS" "$OUT/authorized_keys"

secret() { sops --decrypt --extract "[\"stringData\"][\"$1\"]" "$SECRETS"; }
umask 077
client_secret=$(secret dex_omni_client_secret)
printf 'OMNI_AUTH_OIDC_CLIENT_SECRET=%s\n' "$client_secret" > "$OUT/secrets/omni.env"
printf 'DEX_OMNI_CLIENT_SECRET=%s\nDEX_ADMIN_PASSWORD_HASH=%s\n' \
  "$client_secret" "$(secret dex_admin_password_hash)" > "$OUT/secrets/dex.env"
printf 'CLOUDFLARE_DNS_API_TOKEN=%s\n' "$(secret cloudflare_dns_api_token)" > "$OUT/secrets/lego.env"
# LUKS key for the omni-data partition; changing it orphans the existing data.
printf '%s' "$(secret omni_data_luks_key)" > "$OUT/secrets/omni-data.key"

# Network boot: the host builds ipxe.efi itself (too big for the ISO's
# embedded Ignition), so only its inputs and the menu go in.
mkdir -p "$OUT/pxe"
cp pxe/build-ipxe.sh pxe/embed.ipxe "$OUT/pxe/"
cp "$PXE_MENU" "$OUT/pxe/boot.ipxe"

butane --strict --files-dir "$OUT" "$OUT/omni.bu" > "$OUT/omni.ign"
echo "wrote $OUT/omni.ign"
