# Omni host playbook

Builds or converges the self-hosted Omni host described in
[`omni-server/README.md`](../../omni-server/README.md). Flux can't manage this
host because it sits outside the cluster, so this playbook does.

| Area | What it sets |
|---|---|
| OS | unattended security upgrades, with an automatic reboot at 04:30 when one is needed |
| SSH | keys only, no root login, `AllowUsers` the admin account; asserts a key is installed first |
| Firewall | ufw default-deny; SSH and Omni/Dex ports open to `omni_allowed_cidrs`; anything inside the SideroLink tunnel allowed; Omni's metrics (2122) and internal API (10000) closed to the LAN |
| Docker | official apt repository, capped container logs |
| TLS | pinned, checksum-verified lego; weekly renewal timer; key `0640`, not world-readable |
| Omni | repo checkout, `.env` (created once, never overwritten), permissions on `secrets/`, `data/`, `.lego/`, then `docker compose up -d` |
| Backups | weekly encrypted archive of `data/`, keys, TLS and `.env`; an extra one before any Omni version change |

## Run

```bash
cd ansible/omni-host
ansible-galaxy collection install -r requirements.yaml
ansible-playbook site.yaml --ask-become-pass --diff --check   # preview
ansible-playbook site.yaml --ask-become-pass --diff
```

`--tags` limits it to one area, e.g. `--tags firewall`.

## Secrets

Nothing secret is in git. On the existing host the playbook moves the Dex admin
password hash out of the hand-edited `dex.yaml` into `.env` and resets
`dex.yaml` to the committed version. A new host needs, once:

```bash
ansible-playbook site.yaml --ask-become-pass \
  -e omni_admin_password_hash="$(htpasswd -bnBC 10 '' '<password>' | tr -d ':\n')" \
  -e cloudflare_dns_api_token=<token>
```

and the GPG key from `omni-server/README.md` step 1, or a restored backup in
`omni-server/`. The client secret is generated.
