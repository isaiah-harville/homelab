# Self-hosted Omni

The Talos management plane for the homelab cluster. It runs **outside** the
cluster on a LAN Docker host so it survives a full node wipe. Omni replaces the
old Ansible-based provisioning and manages cluster lifecycle; Talos provides the
control-plane VIP.

> **Where it runs: a dedicated Ubuntu Server box, `10.1.10.88`** (hostname `omni`) —
> deliberately **not** a cluster node, so it survives a full cluster wipe. Omni was
> first stood up on dl380 during the rebuild, then migrated here (copy the whole
> `~/omni-server` — `data/` holds the etcd+sqlite state; `member/` under it is
> root-owned, so `tar` it with sudo) so dl380 could itself be enrolled as a Talos
> worker. The host also auto-renews its cert (see the lego systemd timer below).
>
> **DNS (split-horizon gotcha):** the LAN resolver (`10.1.1.1`) wildcards
> `*.int.harville.dev` → `10.1.10.251` (the traefik LB), and the Omni box itself
> resolves `*.int` out to Cloudflare's proxied edge — **neither points at Omni.**
> So two overrides are needed:
> - **LAN resolver (`10.1.1.1`):** add explicit host overrides
>   `omni.int.harville.dev` → `10.1.10.88` and `omni-dex.int.harville.dev` → `10.1.10.88`
>   so browsers (and later the nodes) reach Omni. (To test before touching LAN DNS,
>   add the same two lines to your workstation's `/etc/hosts`.) **Note the Dex host is
>   `omni-dex.int`, not `dex.int`** — Omni's Dex is scoped so it never contends with the
>   generic `dex.int` name (nothing else uses it today, but don't squat it).
> - **On the Omni host:** `/etc/hosts` needs
>   `10.1.10.88 omni.int.harville.dev omni-dex.int.harville.dev` so the host-networked
>   Omni container resolves Dex (and its own advertised URL) to itself, not Cloudflare.

## Ports

| Port  | Purpose                        |
|-------|--------------------------------|
| 443   | Omni UI / API                  |
| 8090  | Machine API (SideroLink setup) |
| 8091  | Event sink                     |
| 8100  | Kubernetes API proxy           |
| 5556  | Dex OIDC                       |
| 50180/udp | SideroLink WireGuard       |

## One-time setup

### 1. GPG key (etcd data encryption)

```bash
mkdir -p secrets
# Primary key is cert-only; Omni needs an ENCRYPTION subkey to seal the etcd
# key slot — generate the primary THEN add an [E] subkey (both steps required,
# or Omni fails with "key ... has no valid encryption keys").
gpg --batch --passphrase '' --quick-generate-key \
  "Omni (etcd encryption) omni@int.harville.dev" rsa4096 cert never
FPR=$(gpg --list-keys --with-colons omni@int.harville.dev | awk -F: '/^fpr/{print $10; exit}')
gpg --batch --passphrase '' --quick-add-key "$FPR" rsa4096 encrypt never
# Omni v1.9 wants BOTH: public key to encrypt the slot, secret key to decrypt.
gpg --export-secret-keys --armor omni@int.harville.dev > secrets/omni.asc
gpg --export        --armor omni@int.harville.dev > secrets/omni-public.asc
chmod 600 secrets/omni.asc
```

### 2. TLS cert via lego (Cloudflare DNS-01)

The `*.int.harville.dev` wildcard covers both `omni.` and `omni-dex.` hostnames. Mint
it independently of the cluster (Omni is external) using the **same Cloudflare
token** the cluster's cert-manager uses. You can pull that token straight from the
running cluster instead of hunting for it:

```bash
export CLOUDFLARE_DNS_API_TOKEN=$(kubectl -n cert-manager get secret \
  cloudflare-api-token -o jsonpath='{.data.api-token}' | base64 -d)
# lego v5: --email/--dns/--domains/--accept-tos are RUN subcommand flags.
lego run --accept-tos \
     --email harvillerisaiah@gmail.com \
     --dns cloudflare \
     --domains '*.int.harville.dev'
# Then stage the files Omni/Dex expect (lego writes under ./.lego by default):
mkdir -p certs
cp .lego/certificates/_.int.harville.dev.crt   certs/server-chain.pem
cp .lego/certificates/_.int.harville.dev.key   certs/server-key.pem
# CA bundle Omni trusts (Let's Encrypt roots are in the system store).
cp /etc/ssl/certs/ca-certificates.crt          certs/ca.pem
# Dex runs as uid 1001 and must be able to read the cert+key it mounts:
chmod 644 certs/*.pem
```

**Auto-renewal** is a systemd timer on this host: `omni-cert-renew.timer` runs
`/usr/local/bin/omni-cert-renew.sh` weekly, which re-runs `lego run --renew-days 30
--reuse-key` (lego v5 has no `renew` subcommand) and, via `--deploy-hook`, re-copies
the cert into `certs/` and `docker compose restart`s. The Cloudflare token lives in
`~/omni-server/.lego-cf.env` (mode 600).

### 3. Dex break-glass admin password

```bash
htpasswd -bnBC 10 "" 'a-strong-password' | tr -d ':\n'
# paste into dex.yaml staticPasswords[0].hash
```

### 4. Config

```bash
cp .env.example .env      # fill in OMNI_LAN_IP, DEX_OMNI_CLIENT_SECRET, etc.
# make dex.yaml staticClients[0].secret == DEX_OMNI_CLIENT_SECRET
```

### 5. Bring up

```bash
docker compose up -d
docker compose logs -f omni      # wait for "Omni is ready"
```

Open `https://omni.int.harville.dev`, log in as the Dex break-glass admin.

### 6. omnictl

```bash
# Download omnictl from the Omni UI (it embeds your endpoint + service account).
omnictl get machines        # empty until machines join (see ../talos/README.md)
```

## Day-2: unified SSO via authelia

Once the cluster is up and authelia is running:

1. Register an OIDC client `dex` in authelia (redirect
   `https://omni-dex.int.harville.dev:5556/callback`).
2. Uncomment the `authelia` connector in `dex.yaml`, fill the client secret,
   `docker compose restart dex`.
3. Human logins now flow **omni → dex → authelia**. Keep the static admin as
   break-glass for when the cluster is down.

## Backup and restore

The `data/` directory contains Omni's embedded etcd and SQLite databases. Back up
the full runtime state while the stack is stopped:

```bash
docker compose stop
sudo tar -czf /secure/path/omni-backup.tgz \
  data secrets certs .env dex.yaml compose.yaml
docker compose start
```

The archive contains private keys and credentials; store it encrypted. Restore
it on the same paths and start the pinned Omni version before upgrading.

## Layout

```
compose.yaml          Dex + Omni
.env.example          copy to .env
dex.yaml              OIDC config (static admin + authelia connector)
certs/                lego-minted TLS (gitignored)
secrets/omni.asc      GPG etcd key (gitignored)
data/                 embedded etcd + SQLite state (gitignored)
```
