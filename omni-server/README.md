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
> **DNS:** point `omni.int.harville.dev` and `dex.int.harville.dev` at this host's
> IP (`10.1.10.10` for now) so the browser, the nodes, and Omni↔Dex resolve it.

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
gpg --batch --passphrase '' --quick-generate-key \
  "Omni (etcd encryption) omni@int.harville.dev" rsa4096 cert never
gpg --export-secret-key --armor omni@int.harville.dev > secrets/omni.asc
```

### 2. TLS cert via lego (Cloudflare DNS-01)

The `*.int.harville.dev` wildcard covers both `omni.` and `dex.` hostnames. Mint
it independently of the cluster (Omni is external) using the **same Cloudflare
token** the cluster's cert-manager uses:

```bash
export CLOUDFLARE_DNS_API_TOKEN=<same token as infra secret>
lego --email harvillerisaiah@gmail.com \
     --dns cloudflare \
     --domains '*.int.harville.dev' \
     run
# Then stage the files Omni/Dex expect:
mkdir -p certs
cp ~/.lego/certificates/_.int.harville.dev.crt   certs/server-chain.pem
cp ~/.lego/certificates/_.int.harville.dev.key   certs/server-key.pem
# CA bundle Omni trusts (Let's Encrypt roots are in the system store; if Omni
# needs an explicit bundle, point ca.pem at the issuer chain or the system CAs).
cp /etc/ssl/certs/ca-certificates.crt             certs/ca.pem
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
