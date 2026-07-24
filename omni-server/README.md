# Self-hosted Omni

The Talos management plane for the homelab cluster. Runs **outside** the cluster
it manages (Docker host on the LAN) so it survives a full node wipe — this is
what replaces Ansible + kube-vip for provisioning and control-plane lifecycle.

> **Where to run it (for now): dl380, `10.1.10.10`.** Omni must stay up while the
> nodes are re-imaged, so it can't live on a node being enrolled. dl380 is a
> planned *worker*, so run Omni there first, enroll dl380 **last**, and migrate
> Omni off it (to another always-on Docker host) before wiping dl380 — Omni's
> state is `data/etcd/`, so migration = copy that dir + the `certs/`/`secrets/`.
>
> **DNS (split-horizon gotcha):** the LAN resolver (`10.1.1.1`) wildcards
> `*.int.harville.dev` → `10.1.10.251` (the traefik LB), and the Omni box itself
> resolves `*.int` out to Cloudflare's proxied edge — **neither points at Omni.**
> So two overrides are needed:
> - **LAN resolver (`10.1.1.1`):** add explicit host overrides
>   `omni.int.harville.dev` → `10.1.10.10` and `dex.int.harville.dev` → `10.1.10.10`
>   so browsers (and later the nodes) reach Omni. (To test before touching LAN DNS,
>   add the same two lines to your workstation's `/etc/hosts`.)
> - **On the Omni host:** `/etc/hosts` needs
>   `10.1.10.10 omni.int.harville.dev dex.int.harville.dev` so the host-networked
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
gpg --export-secret-key --armor omni@int.harville.dev > secrets/omni.asc
gpg --export        --armor omni@int.harville.dev > secrets/omni-public.asc
chmod 600 secrets/omni.asc
```

### 2. TLS cert via lego (Cloudflare DNS-01)

The `*.int.harville.dev` wildcard covers both `omni.` and `dex.` hostnames. Mint
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

Set up a renewal cron (`lego ... renew`) that re-copies the files and
`docker compose restart`.

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
   `https://dex.int.harville.dev:5556/callback`).
2. Uncomment the `authelia` connector in `dex.yaml`, fill the client secret,
   `docker compose restart dex`.
3. Human logins now flow **omni → dex → authelia**. Keep the static admin as
   break-glass for when the cluster is down.

## Layout

```
docker-compose.yaml   Dex + Omni
.env.example          copy to .env
dex.yaml              OIDC config (static admin + authelia connector)
certs/                lego-minted TLS (gitignored)
secrets/omni.asc      GPG etcd key (gitignored)
data/etcd/            Omni state (gitignored) — BACK THIS UP
```
