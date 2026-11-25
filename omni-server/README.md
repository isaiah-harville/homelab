# Self-hosted Omni

The Talos management plane for the homelab cluster. It runs **outside** the
cluster on a LAN Docker host so it survives a full node wipe. Omni manages
cluster lifecycle; Talos provides the control-plane VIP.

Run Omni on a dedicated host that is not a cluster member. Before setup, choose
separate Omni and Dex hostnames, ensure both resolve to that host from clients
and the host itself, and allow the connections declared in `compose.yaml`.

DNS is split-horizon.

**Hosts:** the replacement host is Fedora CoreOS, built from
[`coreos/`](coreos/README.md); new hosts and the migration start there.
Production (10.1.10.88) still runs this Compose stack on Ubuntu until it is
cut over. The Ansible playbook that built and converged it has been removed,
so the host is maintained by hand with the steps below. The renewal and
backup timers it installed keep running.

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
export OMNI_GPG_ID=omni@example.invalid
mkdir -p secrets
# Primary key is cert-only; Omni needs an ENCRYPTION subkey to seal the etcd
# key slot — generate the primary THEN add an [E] subkey (both steps required,
# or Omni fails with "key ... has no valid encryption keys").
gpg --batch --passphrase '' --quick-generate-key \
  "Omni (etcd encryption) ${OMNI_GPG_ID}" rsa4096 cert never
FPR=$(gpg --list-keys --with-colons "${OMNI_GPG_ID}" | awk -F: '/^fpr/{print $10; exit}')
gpg --batch --passphrase '' --quick-add-key "$FPR" rsa4096 encrypt never
# Omni v1.9 wants BOTH: public key to encrypt the slot, secret key to decrypt.
gpg --export-secret-keys --armor "${OMNI_GPG_ID}" > secrets/omni.asc
gpg --export        --armor "${OMNI_GPG_ID}" > secrets/omni-public.asc
chmod 600 secrets/omni.asc
```

### 2. TLS cert via lego (Cloudflare DNS-01)

Mint a certificate covering the Omni and Dex hostnames independently of the
cluster using Cloudflare DNS-01. Set `OMNI_DOMAIN` to their shared parent domain:

```bash
export OMNI_DOMAIN=example.internal
export CLOUDFLARE_DNS_API_TOKEN=$(kubectl -n cert-manager get secret \
  cloudflare-api-token -o jsonpath='{.data.api-token}' | base64 -d)
# lego v5: --email/--dns/--domains/--accept-tos are RUN subcommand flags.
lego run --accept-tos \
     --email admin@example.invalid \
     --dns cloudflare \
     --domains "*.${OMNI_DOMAIN}"
# Then stage the files Omni/Dex expect (lego writes under ./.lego by default):
mkdir -p certs
cp ".lego/certificates/_.${OMNI_DOMAIN}.crt" certs/server-chain.pem
cp ".lego/certificates/_.${OMNI_DOMAIN}.key" certs/server-key.pem
# CA bundle Omni trusts (Let's Encrypt roots are in the system store).
cp /etc/ssl/certs/ca-certificates.crt          certs/ca.pem
# Dex runs as uid 1001; compose.yaml adds it to the host user's group, so the
# key stays out of reach of other users:
chmod 644 certs/server-chain.pem certs/ca.pem
chmod 640 certs/server-key.pem
```

**Auto-renewal** is a systemd timer on this host: `omni-cert-renew.timer` runs
`/usr/local/bin/omni-cert-renew.sh` weekly, which re-runs `lego run --renew-days 30
--reuse-key` (lego v5 has no `renew` subcommand) and, via
`/usr/local/bin/omni-cert-deploy.sh`, re-installs the cert into `certs/` and
`docker compose restart`s. The Cloudflare token lives in `.lego-cf.env` (mode
600). All three are installed on the current host.

### 3. Secrets in .env

`dex.yaml` holds no secrets: Dex reads its Omni client secret and the
break-glass admin's password hash from the environment (`secretEnv`,
`hashFromEnv`), and Omni reads the same client secret as
`OMNI_AUTH_OIDC_CLIENT_SECRET`. Compose fills all three from `.env`, so the
host's checkout never differs from git. **Never edit secrets into `dex.yaml`**:
that is what made `git pull` conflict on this host.

```bash
cp .env.example .env && chmod 600 .env
openssl rand -hex 32                                  # DEX_OMNI_CLIENT_SECRET
htpasswd -bnBC 10 "" 'a-strong-password' | tr -d ':\n'  # DEX_ADMIN_PASSWORD_HASH, in single quotes
```

### 4. Bring up

```bash
docker compose up -d
docker compose logs -f omni      # wait for "Omni is ready"
```

Open the Omni hostname configured in `.env`, then log in as the Dex break-glass
admin.

### 5. omnictl

```bash
# Download omnictl from the Omni UI (it embeds your endpoint + service account).
omnictl get machines        # empty until machines join (see ../talos/README.md)
```

## Upgrades

Omni and Dex versions are pinned in `compose.yaml`. Flux image automation
commits patch releases there; minor versions are a deliberate edit. Apply
either on the host, backing up first, because Omni migrates its databases on
start and a downgrade can't undo that:

```bash
sudo systemctl start omni-backup           # encrypted archive in backups/
cd ~/homelab && git pull && cd omni-server
docker compose up -d --pull missing
curl -fsS https://omni.int.harville.dev/healthz && curl -fsS https://omni-dex.int.harville.dev:5556/healthz
```

Read the release notes for removed flags: Omni refuses
to start with one. Upgrade `omnictl` alongside Omni; an older client is
refused once the API version moves. Talos and Kubernetes follow Omni, in that
order: see [Upgrades](https://github.com/isaiah-harville/homelab/blob/main/docs/operations/upgrades.md).

Authentik deliberately does not front Omni or Dex: logging in must keep working
when the cluster is down.

## Machine logs after a crash

Omni stores each machine's kernel log, streamed over SideroLink, in
`data/omni.db`. It keeps up to 200,000 lines per machine for 30 days, which
covers several weeks at normal volume. To read what a node logged before it
reset:

```bash
omnictl machine-logs <machine-id> | grep -B200 '"seq":0,'
```

`seq` restarts at 0 on each boot, so the lines just before a `"seq":0` entry
are the last ones the previous boot sent. A hard panic can stop the stream
before the panic text is sent.

## Backup and restore

### etcd → S3 (seaweedfs), automatic

Omni natively backs up its embedded etcd store on a schedule. The `omni`
container runs with `--etcd-backup-s3`; the bucket/credentials come from an
`EtcdBackupS3Configs` resource (not a compose flag), and the schedule comes
from the cluster's `backupConfiguration` (set in `terraform/omni/cluster.tf`,
mirrored in `talos/omni/cluster-template.yaml`):

```bash
export OMNI_ENDPOINT=https://omni.int.harville.dev/
export OMNI_SERVICE_ACCOUNT_KEY=...   # SA with Admin role

cat <<EOF | omnictl apply -f -
metadata:
  namespace: default
  type: EtcdBackupS3Configs.omni.sidero.dev
  id: etcd-backup-s3-conf
spec:
  bucket: backups
  region: us-east-1
  endpoint: https://s3.int.harville.dev
  accesskeyid: <seaweedfs "omni-backup" identity access key>
  secretaccesskey: <seaweedfs "omni-backup" identity secret key>
  sessiontoken: ""
EOF
```

The `omni-backup` seaweedfs identity (scoped to `Read/Write/List/Tagging` on
the `backups` bucket only) lives in
`apps/seaweedfs/seaweedfs/app/seaweedfs-s3-config.sops.yaml` (SOPS-encrypted).
After editing `compose.yaml` to add the flag, redeploy on the omni host:
`docker compose up -d`. Backups land under `s3://backups/omni/...` in
seaweedfs; list them with `omnictl etcd-backup list --cluster homelab` (or the
Omni UI's Backups tab).

**Restore**: `omnictl cluster template sync` a template with the target
cluster's `id` sourced from the backup, or use the Omni UI "Restore from
backup" flow when creating/re-pointing a cluster. This only restores Omni's
view of cluster/machine state — Talos itself is unaffected.

### Full host state, weekly

The `data/` directory (etcd + SQLite) plus the GPG key, TLS and `.env` are what
make this specific Omni instance work at all, and the S3 etcd backups above
don't cover them. `omni-backup.timer` (Sundays 02:45) stops the stack for a
moment, tars them, encrypts the archive to the repo's age recipient
(`.sops.yaml`) and keeps eight weeks in `backups/`. Run one on demand with
`sudo systemctl start omni-backup`. Restore on a fresh host:

```bash
age -d -i <age identity> backups/omni-<stamp>.tar.gz.age | tar -xz -C omni-server
```

then `docker compose up -d` with the same Omni version the backup came from,
and upgrade only after that. (A CoreOS host restores the same archive with
`omni-restore`.) The archives sit on the Omni host itself, so copy them
somewhere else as well.

## Layout

```
compose.yaml          Dex + Omni
.env.example          copy to .env (all secrets live there)
dex.yaml              OIDC config (break-glass admin; no secrets)
certs/                lego-minted TLS (gitignored)
secrets/omni.asc      GPG etcd key (gitignored)
data/                 embedded etcd + SQLite state (gitignored)
backups/              encrypted weekly host backups (gitignored)
```
