# Shared helpers for the omni-* scripts. Sourced, not executed.

OMNI_STATE=/var/lib/omni
OMNI_ETC=/etc/omni
DEX_GID=1001

# host.env is KEY=value lines that systemd also reads, so values may contain
# spaces and are never run through a shell.
load_env() {
  local k v
  while IFS='=' read -r k v; do
    [[ $k =~ ^[A-Z_][A-Z0-9_]*$ ]] && export "$k=$v"
  done < "$1"
}

log() { printf '%s\n' "$*" >&2; }

# Wait until Omni and Dex answer /healthz. /etc/hosts maps both names to this
# host, so this checks TLS and the names without depending on LAN DNS.
omni_health() {
  local tries=${1:-60} i
  for ((i = 1; i <= tries; i++)); do
    if curl -fs -o /dev/null --max-time 5 "https://${OMNI_HOST}/healthz" &&
      curl -fs -o /dev/null --max-time 5 "https://${DEX_HOST}:5556/healthz"; then
      log "omni and dex are healthy"
      return 0
    fi
    sleep 5
  done
  log "omni or dex did not become healthy"
  return 1
}

load_env "$OMNI_ETC/host.env"
