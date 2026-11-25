# Omni host playbook

Builds and converges the self-hosted Omni host (`10.1.10.88`) described in
[`omni-server/README.md`](../../omni-server/README.md). The host sits outside
the cluster on purpose, so Flux can't manage it; this playbook does. It is the
only supported way to change the host, including Omni and Dex upgrades.

## Run it

```bash
cd ansible/omni-host
ansible-galaxy collection install -r requirements.yaml
ansible-playbook site.yaml --ask-become-pass --diff --check   # preview
ansible-playbook site.yaml --ask-become-pass --diff
```

`--ask-become-pass` prompts for `isaiah`'s sudo password on the host.
`--tags` limits a run to one area: `base`, `ssh`, `firewall`, `docker`,
`lego` or `omni`. An Omni or Dex upgrade only needs `--tags omni`.

`--check` previews everything, but two steps can only be simulated: moving the
Dex hash into `.env` and resetting `dex.yaml`. On a host that still has a
hand-edited `dex.yaml`, the preview's "Update the checkout" step therefore
reports an error it ignores; a real run does the reset first.

## What it manages

| Area | What it sets |
|---|---|
| OS (`base`) | Unattended security upgrades, rebooting at 04:30 when an update needs it. The cluster keeps running while Omni restarts. |
| SSH (`ssh`) | Keys only, no root login, `AllowUsers isaiah`. Refuses to run unless a key is already authorized. Asks the running server which login methods it offers and reloads sshd if passwords are still allowed. |
| Firewall (`firewall`) | ufw default-deny. SSH, Omni (443, 8090, 8100), Dex (5556) and SideroLink WireGuard (50180/udp) open to `10.1.0.0/16`; everything inside the `siderolink` tunnel allowed. Omni's metrics (2122) and internal API (10000) are closed to the LAN. |
| Docker (`docker`) | Docker's apt repository (deb822), Engine and Compose, container logs capped at 5 × 20 MB. |
| TLS (`lego`) | lego at a pinned, checksum-verified version. A weekly timer renews the `*.int.harville.dev` certificate (Cloudflare DNS-01) inside 30 days of expiry; the private key is `0640`. |
| Omni (`omni`) | Repository checkout, `.env`, permissions on `secrets/`, `data/`, `.lego/`, `docker compose up -d`, health checks and backups (below). |

Everything is in `inventory.yaml` (variables) and `tasks/`; the scripts and
systemd units it installs are in `templates/`.

## Secrets

Nothing secret is in Git. `omni-server/.env` (mode 600) holds the Dex client
secret and the break-glass admin's bcrypt hash; `dex.yaml` and `compose.yaml`
read them from the environment. The playbook creates `.env` once and never
overwrites it.

On a host whose `dex.yaml` still has the hash edited into it, the playbook
moves the hash into `.env`, resets `dex.yaml` to Git, and drops any `git stash`
that holds nothing but `omni-server/dex.yaml` (those stashes contain the old
secrets).

A **new host** needs, once:

```bash
ansible-playbook site.yaml --ask-become-pass \
  -e omni_admin_password_hash="$(htpasswd -bnBC 10 '' '<password>' | tr -d ':\n')" \
  -e cloudflare_dns_api_token=<token>
```

plus the GPG key from `omni-server/README.md` step 1, or a restored backup in
`omni-server/`. The client secret is generated.

## Upgrades

Omni and Dex are pinned in `omni-server/compose.yaml`. Flux image automation
commits patch releases there on `main`; minor versions are a deliberate edit.
Either way, the host changes only when the playbook runs:

1. It notes the change (`omni:v1.14.0 -> omni:v1.14.1`).
2. It takes an encrypted backup (below), because Omni migrates its databases
   on start and a tag change can't undo that.
3. It runs `docker compose up -d`.
4. It waits up to 3 minutes for `https://omni.int.harville.dev/healthz` and 2
   minutes for Dex's `/healthz`, then reports the running images.

If a health check fails, the run stops and the backup is the rollback. The
order relative to Talos and Kubernetes upgrades is in
[Upgrades](https://github.com/isaiah-harville/homelab/blob/main/docs/operations/upgrades.md).

## Backups

`omni-backup.timer` runs Sundays at 02:45; the playbook also runs it before any
Omni version change. It stops Omni and Dex for the copy, archives `data/`,
`secrets/`, `certs/`, `.env`, `.lego/` and `.lego-cf.env`, encrypts the archive
to the repo's age recipient (`.sops.yaml`) and keeps eight weeks in
`omni-server/backups/` (root-only). Run one by hand with
`sudo systemctl start omni-backup`; restore with

```bash
age -d -i <age identity> omni-server/backups/omni-<stamp>.tar.gz.age | tar -xz -C omni-server
```

then run the playbook and start the Omni version the backup came from. The
archives live on the Omni host itself, so copy one elsewhere before a risky
change.
