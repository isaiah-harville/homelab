#!/usr/bin/env bash
# Set the Dex break-glass admin password in secrets.sops.yaml: prompts for
# it, stores its bcrypt hash (what Dex reads) and the plaintext (so it stays
# recoverable with the age identity). The password never appears in argv or
# the shell history. Takes effect on the next install (make iso).
#
#   SOPS_AGE_KEY_FILE=~/Projects/homelab/.agekey omni-server/coreos/set-dex-password.sh
set -euo pipefail
cd "$(dirname "$0")"
SECRETS=${SECRETS:-secrets.sops.yaml}
command -v htpasswd > /dev/null || { echo "needs htpasswd (macOS has it; apache2-utils on Linux)" >&2; exit 1; }

read -rsp 'New Dex admin password: ' pw && echo
read -rsp 'Again: ' again && echo
[[ $pw == "$again" ]] || { echo "passwords differ" >&2; exit 1; }
((${#pw} >= 16)) || { echo "use at least 16 characters" >&2; exit 1; }

hash=$(printf '%s' "$pw" | htpasswd -niBC 12 admin | cut -d: -f2 | tr -d '\n')
json() { python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'; }
printf '%s' "$hash" | json | sops set --value-stdin "$SECRETS" '["stringData"]["dex_admin_password_hash"]'
printf '%s' "$pw" | json | sops set --value-stdin "$SECRETS" '["stringData"]["dex_admin_password"]'
echo "updated $SECRETS; commit it, then rebuild the ISO (make iso)"
