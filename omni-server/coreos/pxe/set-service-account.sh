#!/usr/bin/env bash
# Create, or renew, the Omni service account the host uses to build its
# network-boot menu (pxe-menu), and store the key in secrets.sops.yaml. Run
# it once with omnictl logged in to this Omni, commit secrets.sops.yaml, and
# reinstall. That key only bootstraps the host: pxe-menu renews the account
# itself every 30 days and keeps the current key on omni-data, so there is no
# yearly chore. Run this again only for a host whose omni-data and backups
# are both gone. The key never touches argv, the screen or the shell history.
#
#   SOPS_AGE_KEY_FILE=~/Projects/homelab/.agekey omni-server/coreos/pxe/set-service-account.sh
set -euo pipefail
cd "$(dirname "$0")/.."
name=pxe-menu
# Omni caps service-account keys at a year.
ttl=${TTL:-8760h}

if omnictl serviceaccount list 2> /dev/null | awk 'NR > 1 {print $1}' | grep -qx "$name"; then
  out=$(omnictl serviceaccount renew "$name" --ttl "$ttl")
else
  # Admin, so pxe-menu can renew its own key. Root on the Omni host controls
  # Omni anyway (its databases and etcd key live there), so this adds no
  # real exposure.
  out=$(omnictl serviceaccount create "$name" --use-user-role=false --role Admin --ttl "$ttl")
fi
key=$(sed -nE 's/^OMNI_SERVICE_ACCOUNT_KEY=//p' <<< "$out")
[[ -n $key ]] || { echo "omnictl printed no OMNI_SERVICE_ACCOUNT_KEY" >&2; exit 1; }

printf '%s' "$key" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))' |
  sops set --value-stdin secrets.sops.yaml '["stringData"]["omni_pxe_service_account_key"]'
echo "stored the $name key in secrets.sops.yaml (TTL $ttl); commit it and reinstall"
