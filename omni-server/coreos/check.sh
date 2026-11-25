#!/usr/bin/env bash
# Static checks for the CoreOS Omni host config. Nothing is rendered or
# built and no secrets are needed: CI runs this on every PR that touches
# omni-server/coreos (.github/workflows/validate.yaml).
#
#   omni-server/coreos/check.sh
#
# Needs shellcheck and skopeo (both on GitHub's ubuntu-latest runners).
set -euo pipefail
cd "$(dirname "$0")"
failed=0
fail() {
  echo "FAIL: $*" >&2
  failed=1
}

echo "== shellcheck"
scripts=(render.sh check.sh set-dex-password.sh pxe/*.sh test/*.sh files/bin/*)
# SC1091: omni-lib.sh is sourced from its installed path. SC2016: literal
# ${VARS} handed to envsubst and sops on purpose.
shellcheck -x -e SC1091,SC2016 --severity=warning "${scripts[@]}" || fail "shellcheck"

echo "== secrets.sops.yaml is encrypted"
if grep -qE '^sops:' secrets.sops.yaml; then
  values=$(sed -n '/^stringData:/,/^[^ ]/p' secrets.sops.yaml | grep -E '^[[:space:]]+[a-z_]+:' || true)
  [[ -n $values ]] || fail "secrets.sops.yaml has no stringData values"
  plain=$(grep -v 'ENC\[' <<< "$values" || true)
  [[ -z $plain ]] || fail "plaintext values in secrets.sops.yaml: $(sed -E 's/:.*//' <<< "$plain" | tr -d ' ' | tr '\n' ' ')"
else
  fail "secrets.sops.yaml has no sops metadata"
fi

echo "== every local: file in omni.bu exists"
# Paths under the render output that render.sh creates rather than copies.
generated='^(secrets/|host\.env$|authorized_keys$|pxe/boot\.ipxe$)'
while read -r path; do
  [[ $path =~ $generated ]] && continue
  [[ -f $path ]] || fail "omni.bu references missing file $path"
done < <(sed -nE 's/^[[:space:]]*(local|contents_local):[[:space:]]*(.+)$/\2/p' omni.bu |
  grep -v '^-' | tr -d '"')
while read -r path; do
  [[ $path =~ $generated ]] && continue
  [[ -f $path ]] || fail "omni.bu references missing file $path"
done < <(grep -oE '^[[:space:]]+- local: .+' omni.bu | sed -E 's/.*local: //')

echo "== every \${VAR} in the templates is defined"
defined=$(sed -nE 's/^([A-Z_][A-Z0-9_]*)=.*/\1/p' host.env)
# Image refs from versions.yaml; units leave them for systemd to expand
# from images.env.
defined+=$'\n'"OMNI_IMAGE DEX_IMAGE LEGO_IMAGE TOOLS_IMAGE IPXE_BUILD_IMAGE"
mapfile -t templates < <(find files -type f ! -path 'files/bin/*')
templates+=(omni.bu)
# Comment lines may mention ${VARS} in prose; only real substitutions count.
for var in $(grep -hvE '^[[:space:]]*#' "${templates[@]}" | grep -oE '\$\{[A-Z_][A-Z0-9_]*\}' | tr -d '${}' | sort -u); do
  grep -qw "$var" <<< "$defined" || fail "\${$var} is used in a template but not set in host.env"
done
for var in $(sed -nE 's/^([A-Z_][A-Z0-9_]*)=.*/\1/p' test/host.env); do
  grep -qw "$var" <<< "$defined" || fail "test/host.env sets $var, which host.env lacks"
done
for var in $(sed -nE 's/^([A-Z_][A-Z0-9_]*)=.*/\1/p' host.env); do
  grep -q "^$var=" test/host.env || fail "host.env sets $var, which test/host.env lacks"
done

echo "== pinned images exist"
for key in omni dex lego tools ipxe-build; do
  ref=$(sed -nE "s/^[[:space:]]*$key:[[:space:]]*([^[:space:]#]+).*/\1/p" versions.yaml | head -n1)
  [[ -n $ref ]] || { fail "versions.yaml has no $key image"; continue; }
  # Flux's setters write tag-only refs for omni and dex (omni-sync pins those
  # on the host); the rest must carry a digest.
  if [[ $key != omni && $key != dex && $ref != *@sha256:* ]]; then
    fail "$key is not pinned by digest: $ref"
  fi
  # A tag@digest ref must still name a tag that points at that digest.
  if [[ $ref == *@sha256:* ]]; then
    want=${ref#*@} tagged=${ref%@*}
    got=sha256:$(skopeo inspect --raw "docker://$tagged" | sha256sum | cut -d' ' -f1)
    [[ $got == "$want" ]] || echo "note: $tagged now points at $got, not the pinned $want"
    skopeo inspect --raw "docker://${tagged%:*}@$want" > /dev/null || fail "$ref does not exist"
  else
    skopeo inspect --raw "docker://$ref" > /dev/null || fail "$ref does not exist"
  fi
done

echo "== iPXE scripts"
for f in pxe/boot.ipxe pxe/embed.ipxe; do
  [[ $(head -n1 "$f") == '#!ipxe' ]] || fail "$f does not start with #!ipxe"
done
# A failing iseq ends an iPXE script unless followed by ||.
bad=$(grep -nE '^[[:space:]]*iseq ' pxe/boot.ipxe pxe/embed.ipxe | grep -v '||' || true)
[[ -z $bad ]] || fail "iseq without || (ends the script when unequal): $bad"

if ((failed)); then
  exit 1
fi
echo "all checks passed"
