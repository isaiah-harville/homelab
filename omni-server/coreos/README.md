# Omni host on Fedora CoreOS (prototype)

An image-based replacement for the Ubuntu + Ansible Omni host
([`ansible/omni-host`](../../ansible/omni-host/README.md)). The whole host is
one Butane file in git, rendered to Ignition with secrets from SOPS and
installed from an ISO. Nothing is converged in place. To change the host,
change git and reinstall. Omni's state lives on its own partition, which
the reinstall keeps.

Omni and Dex run as Docker containers from plain systemd units, with the
same flags as [`compose.yaml`](../compose.yaml). That is Sidero's supported
container-on-Linux path. Docker is FCOS's `moby-engine`, which ships in
the OS; nothing is layered.

**Status:** validated in a throwaway VM (see [Validation](#validation)). The
production host (10.1.10.88) still runs the Compose stack. Cutover is the
[migration](#migrate-from-the-ansible-host) below.

## Layout

```
omni.bu               Butane config (the host)
host.env              non-secret settings: names, LAN IP, firewall CIDRs, disk
versions.yaml         pinned images; Flux bumps omni/dex patch releases here
secrets.example.yaml  template for secrets.sops.yaml (SOPS/age, never plaintext)
render.sh             host.env + versions.yaml + SOPS -> build/omni.ign
installer.yaml        coreos-installer config: keep the omni-data partition
Makefile              make ign | make iso
files/units/          omni, dex, lego, tools-image, backup, sync units + timers
files/bin/            omni-backup, omni-restore, omni-sync, omni-health, ...
files/etc/            dex.yaml, nftables, Zincati, sshd, /etc/hosts, tmpfiles
test/                 QEMU harness used for validation
build/                rendered output: contains secrets, gitignored
```

## What the host looks like

| Piece | How |
|-------|-----|
| OS | Fedora CoreOS stable, auto-updated by Zincati in a weekly window (Sun 04:30 UTC, 60 min) |
| Disk | Partitions 1-4 are FCOS (root capped at `ROOT_SIZE_MIB`); partition 5 `omni-data` is the rest, mounted at `/var/lib/omni` |
| Encryption | Root is LUKS, unlocked by the TPM2 (clevis). `omni-data` is LUKS with a key file from SOPS, stored on the encrypted root (see [findings](#findings)) |
| Omni | `omni.service`: `docker run --network host --cap-add NET_ADMIN --device /dev/net/tun`, image pinned by digest, `OMNI_AUTH_OIDC_CLIENT_SECRET` from root-only `/etc/omni/omni.env`, metrics on `127.0.0.1:2122` |
| Dex | `dex.service` on 5556 (host network), `dex.yaml` uses `secretEnv`/`hashFromEnv`; started before Omni |
| TLS | lego (Cloudflare DNS-01) in a container, `omni-cert-renew.timer` weekly; `omni-cert-deploy` installs a changed cert (key `root:1001 0640`, readable by Dex's uid) and restarts Omni and Dex |
| Backups | `omni-backup.timer` weekly, plus one before every upgrade; same age-encrypted archive as the Ansible host |
| Day 2 | `omni-sync.timer` daily: reads `versions.yaml` from main, backs up, swaps images, checks `/healthz` |
| Firewall | nftables (FCOS has no firewalld): 10.1.0.0/16 to 22, 443, 5556, 8090, 8100 and 50180/udp; anything on `siderolink`; everything else dropped (closes 2122 and 10000) |
| SSH | keys only, `core` only; FCOS already disables passwords |
| SELinux | Off (`selinux=0`); see [findings](#findings) |

State on `omni-data` (`/var/lib/omni`) has the same layout as the Compose
host's `omni-server/` directory: `data/` (etcd + SQLite), `secrets/omni.asc`
and `omni-public.asc` (the GPG key that seals etcd), `certs/`, `.lego/` and
`backups/`. That keeps backups interchangeable between the two hosts.

## Bootstrap a new host

Needs `butane`, `sops` (with the age identity), `envsubst` (gettext) and
Docker for coreos-installer.

1. Create the secrets once (from the repo root, so `.sops.yaml` applies):

   ```bash
   cp omni-server/coreos/secrets.example.yaml omni-server/coreos/secrets.sops.yaml
   $EDITOR omni-server/coreos/secrets.sops.yaml
   sops --encrypt --in-place omni-server/coreos/secrets.sops.yaml
   ```

   For a migration, copy `DEX_OMNI_CLIENT_SECRET` and the
   `DEX_ADMIN_PASSWORD_HASH` from the old host's `.env`. This keeps the
   break-glass password. The client secret could just as well be new.
   `omni_data_luks_key` must never change once a host uses it.

2. Check `host.env`. `INSTALL_DEVICE` must be the target disk as the live ISO
   sees it (`lsblk`). `OMNI_LAN_IP` is the address machines' WireGuard
   endpoint uses; keep 10.1.10.88 when replacing the current host.

3. Build the install ISO and boot the machine from it (USB or virtual media):

   ```bash
   cd omni-server/coreos
   make iso            # build/omni-install.iso, x86_64 stable stream
   ```

   The ISO installs to `INSTALL_DEVICE` without asking, keeping only an
   existing `omni-data` partition, and reboots. Remove the USB stick once it
   has installed. **The ISO and `build/` contain the secrets: delete them
   afterwards.**

4. First boot: Ignition partitions and encrypts the disk, then reboots once
   to apply `selinux=0`. After that it creates the GPG key (if
   `secrets/omni.asc` doesn't exist) and issues the certificate with lego (if
   `certs/` is empty). Then it starts Dex and Omni. Check with:

   ```bash
   ssh core@omni.int.harville.dev sudo omni-health
   ```

The Ignition config isn't kept on the host: FCOS deletes it from `/boot`
after first boot, and the secrets it carried live only on the encrypted
root.

## Change the host

Everything except image versions is a reinstall: edit `omni.bu`, `files/`,
`host.env` or the secrets, `make iso`, boot it. The installer keeps
`omni-data`, and Ignition reuses its partition, LUKS volume and filesystem.
Omni comes back with all its state, and joined machines reconnect on their
own. A reinstall takes about as long as a reboot plus a minute.

## Upgrade Omni or Dex

Patch releases arrive in `versions.yaml` via Flux image automation (the
existing `omni-host` ImageUpdateAutomation already covers
`./omni-server`). Minor releases are a deliberate edit there, after
reading Omni's release notes for removed flags. Either way nothing touches
the host until `omni-sync` runs:

- `omni-sync.timer` runs daily at 05:45 UTC (after the OS update window).
  To apply now: `sudo systemctl start omni-sync`, or `sudo omni-sync
  --dry-run` to see what would change.
- It reads `versions.yaml` from `VERSIONS_URL` (main on GitHub) and pulls
  the new images first. A tag-only ref, which is what Flux's setters write,
  gets resolved to a digest and pinned. It takes a `pre-upgrade` backup,
  rewrites `/etc/omni/images.env` (keeping `images.env.prev`) and restarts
  the changed services. Then it waits for `https://<omni>/healthz` and
  `https://<dex>:5556/healthz`.
- There is no automatic rollback, as with the playbook: Omni migrates its
  databases on start. To go back, copy `images.env.prev` over `images.env`
  and `omni-restore` the `pre-upgrade` archive.

Order still matters for Talos and Kubernetes:
[Upgrades](../../docs/operations/upgrades.md). Upgrade `omnictl` alongside.

**Sync vs. reinstall-on-change.** Both work. A reinstall for every image
bump would mean a new ISO, console access and a reboot for each patch
release. That is a lot of ceremony for a two-line change, and it couldn't
be triggered from git without PXE. The sync timer keeps Flux's existing
flow (bot commits a bump, the host applies it with a backup and a health
check) and touches only `images.env`. **Recommendation: sync for image
versions, reinstall for everything else.** Re-rendering the whole host
from git on a timer would need the SOPS identity on the host, which is
what this design avoids.

## Backups and restore

`omni-backup` stops Omni and Dex, tars `data secrets certs .lego` plus `.env`
and `.lego-cf.env` (rebuilt from `/etc/omni` in the Compose format), and
encrypts the archive to `BACKUP_AGE_RECIPIENT` (the repo's age recipient).
Archives go to `/var/lib/omni/backups`, and those older than 56 days are
pruned. It runs Sundays 02:45 UTC and before every upgrade.
`sudo systemctl start omni-backup` takes one now. As before, copy archives
off the host too.

Restore keeps the age identity off the host by decrypting on your machine:

```bash
age -d -i <identity> omni-<stamp>.tar.gz.age | ssh core@omni.int.harville.dev sudo omni-restore -
```

`omni-restore` checks the archive has `data/` and the GPG key, warns if its
hostnames differ from this host's, stops Omni and Dex, moves the current state
to `/var/lib/omni/pre-restore-<stamp>/`, puts the archive's in place, fixes
ownership (Dex reads the key through gid 1001), starts both and waits for
health. Secrets in the archive's `.env` aren't applied: `/etc/omni` comes
from `secrets.sops.yaml`. Start the Omni version the backup came from,
then upgrade.

## Migrate from the Ansible host

1. Pin `versions.yaml` to the version the old host runs (they share Flux's
   bumps, so normally nothing to do).
2. Create `secrets.sops.yaml` (above), reusing the old `.env` values if you
   want the same admin password.
3. On the old host: `sudo systemctl start omni-backup` and copy the newest
   `omni-server/backups/omni-*.tar.gz.age` off it. Then stop the stack
   (`docker compose down`): from here, management is down until step 5. The
   cluster keeps running.
4. Install the new host on the same IP (10.1.10.88) and hostnames, so
   machines' SideroLink endpoint and DNS stay valid. On the same hardware
   the install wipes the Ubuntu disk, so check you have the archive first.
5. Restore: `age -d -i <identity> omni-<stamp>.tar.gz.age | ssh core@<host>
   sudo omni-restore -`. Machines reconnect over SideroLink within a minute
   or two; check `omnictl get links`.
6. Retire `ansible/omni-host` and `omni-server/compose.yaml`, and point the
   Flux setters (already scoped to `./omni-server`) only at `versions.yaml`.

## Validation

Done in QEMU on an Apple Silicon Mac (aarch64 FCOS and Talos, HVF,
swtpm vTPM) with the harness in `test/` (`test/README.md`). Nothing
touched the production host or cluster.

Each step ran against the real `omni.bu`, with the test-only differences
listed in `test/README.md`. "Marker" means an Omni user created before the
step, and a joined Talos VM whose SideroLink `Link` had to come back as
`connected: true`.

| Step | Result |
|------|--------|
| Install from the auto-installing ISO (FCOS 44.20261023.3.1) | Root and `omni-data` encrypted. `/var/lib/omni` mounted. GPG key and tools image created. Dex, then Omni, healthy |
| Talos VM joins over SideroLink (Talos 1.13.12) | `Link` connected, machine in maintenance mode |
| Reboot | New boot ID, healthy, marker user and Talos link intact |
| Reinstall from the ISO, keeping `omni-data` | Installer saved partition 5. Ignition reused partition, LUKS and XFS. Same GPG key, marker user present, Talos reconnected |
| Zincati update 44.20261023.3.1 to 45.20261030.3.1 (latest stable) | Staged, rebooted, healthy, state intact. The production window then parsed as "next window at 4:30 on Sun (UTC)" |
| `omni-sync` patch upgrade, Omni v1.13.2 to v1.13.3 | Tag-only ref resolved and pinned by digest, `pre-upgrade` backup written, Omni restarted, both `/healthz` OK; second run "up to date" |
| `omni-sync` minor upgrade to v1.14.0 (the repo's real `versions.yaml`) | Same, Omni reports `backendversion: v1.14.0`, state intact |
| Restore an archive made by the playbook's own `omni-backup.sh.j2` (rendered unchanged, run against a Compose stack of Omni 1.14.0) | `omni-restore -` brought up the old instance on FCOS. Its users and GPG key, Omni 1.14.0 healthy on the restored etcd |
| FCOS `omni-backup` + `omni-restore -i` round trip | Same top-level layout and `.env` format as the playbook's archive. A user created after the backup was gone after the restore |
| Talos 1.14.7 (latest) joins the restored instance | Connected |
| lego against a local Pebble ACME server (in place of Let's Encrypt + Cloudflare) | Certificate issued into `.lego/`. `omni-cert-deploy` installed it (key `root:1001 0640`) and restarted Dex and Omni |
| Firewall | 5556 and 8090 reachable from the allowed CIDR; 10000 and 2122 dropped (time out). Omni 1.14 binds metrics to loopback and nothing on 10000 |

Not tested: a real Let's Encrypt + Cloudflare issuance (no token in the
test, and it would have touched the production DNS zone), a browser login
through Dex (Omni does fetch Dex's discovery document at startup, so TLS and
names work), and x86_64 hardware (the VMs were aarch64; all images are
multi-arch).

## Findings

Things that didn't work at first, and are now handled in the config:

- **Ignition matches partitions by number, not label.** Without
  `number: 5`, a reinstall created a second `omni-data` partition in a 1 MiB
  gap rather than reusing the saved one.
- **Ignition can't reuse a clevis-bound LUKS volume** ("could not be reused:
  config must not specify clevis binding"). A TPM-only `omni-data` volume
  would make every reinstall fail. It now uses a key file from SOPS, kept on
  the TPM-sealed root. At rest the data is still bound to the TPM, and with
  the age identity it can also be opened on another machine.
- **`size_mib: 0` doesn't survive a reinstall on its own.** "Rest of the
  disk" works out ~1 MiB larger than the partition first created, and
  Ignition stopped the boot on the size mismatch. `resize: true` lets it grow
  the partition; it can never shrink it.
- **SELinux blocks Omni.** Under enforcing, a container may not
  inotify-watch Omni's userspace WireGuard socket. The host now boots with
  `selinux=0`. Exempting only Omni (`--security-opt label=disable`) also
  works (tested as Podman's `SecurityLabelDisable`), if you'd rather keep
  SELinux for the rest.
- **Fedora 44 dropped `/etc/pki/tls/certs/ca-bundle.crt`.** The bundle is
  `/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem`. That replaces the
  Compose host's hand-copied `certs/ca.pem` and follows OS updates.
- **Docker won't create missing bind-mount sources** under the data
  partition: `tmpfiles.d` creates them each boot.
- **FCOS has no firewalld** (the task asked for it). The rules are plain
  nftables, loaded by FCOS's `nftables.service`, without layering a
  package.
- **FCOS has no age, and only Docker's deprecated legacy builder.** The
  `omni-tools` image (Alpine + age + gnupg) is made with `docker run` +
  `docker commit` on first boot instead of a Dockerfile.
- **Docker vs Podman.** Podman quadlets also worked (an earlier iteration).
  Podman is FCOS's first-class engine, and Fedora has discussed dropping
  `moby-engine` from FCOS before. If that happens, the units convert back
  to quadlets almost line for line.

Test-environment only (no change to the host config):

- Omni needs SNI: clients must use its hostname, not an IP.
- Talos in maintenance mode can't trust a private CA. For a plaintext
  machine API, the SideroLink URL must be `grpc://`: Talos still tries TLS
  with the `http://` URL Omni advertises when it has no machine-API cert.
  Production uses Let's Encrypt, so it is unaffected.
- On Apple Silicon (HVF) QEMU's TPM needs `ppi=off`. A UEFI-booted Talos VM
  needs `virtio-rng-pci`, or it blocks on entropy. Direct kernel boot has
  no SMBIOS, so Talos never registers.

Open points before production:

- `INSTALL_DEVICE` in `host.env` is a guess (`/dev/sda`); check it on the
  real machine.
- `secrets.sops.yaml` doesn't exist yet: it needs the age identity
  (step 1 of Bootstrap).
- Flux's setters write tag-only refs; `omni-sync` pins the digest at apply
  time. To have Flux write digests into git instead, add
  `digestReflectionPolicy: Always` to the `omni` and `dex` ImagePolicies.
