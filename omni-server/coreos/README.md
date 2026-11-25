# Omni host on Fedora CoreOS

An image-based replacement for the Ubuntu + Docker Compose Omni host
([`omni-server/`](../README.md)). The whole host is
one Butane file in git, rendered to Ignition with secrets from SOPS and
installed from an ISO. Nothing is converged in place. To change the host,
change git and reinstall. Omni's state lives on its own partition, which
the reinstall keeps.

Omni and Dex run as Docker containers from plain systemd units, with the
same flags as the Docker Compose stack they replaced. That is Sidero's supported
container-on-Linux path. Docker is FCOS's `moby-engine`, which ships in
the OS; nothing is layered.

**Status:** in production on 10.1.10.88 since 2026-11-25, replacing the
Ubuntu Docker Compose host (see [the migration](#migration-from-the-compose-host-done-2026-11-25)).
To install or change the host, follow
[Build the install ISO](INSTALL-ISO.md).

## Layout

```
INSTALL-ISO.md        step-by-step guide: build the ISO, write the USB stick, install
check.sh              static checks, run by CI (validate.yaml) on every PR
set-dex-password.sh   set the Dex break-glass password in secrets.sops.yaml
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
pxe/                  network boot: iPXE build, embedded script, menu, Omni presets
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
| Backups | `omni-backup.timer` weekly, plus one before every upgrade; same age-encrypted archive as the Compose host |
| Day 2 | `omni-sync.timer` daily: reads `versions.yaml` from main, backs up, swaps images, checks `/healthz` |
| Network boot | TFTP only (dnsmasq, no DHCP or DNS) serving an iPXE build with an embedded script and a menu that chains Talos from the Image Factory into Omni ([Network boot](#network-boot)) |
| Firewall | nftables (FCOS has no firewalld): 10.1.0.0/16 to 22, 443, 5556, 8090, 8100, 50180/udp and 69/udp; anything on `siderolink`; everything else dropped (closes 2122 and 10000) |
| SSH | keys only, `core` only; FCOS already disables passwords |
| SELinux | Off (`selinux=0`); see [findings](#findings) |

State on `omni-data` (`/var/lib/omni`) has the same layout as the Compose
host's `omni-server/` directory: `data/` (etcd + SQLite), `secrets/omni.asc`
and `omni-public.asc` (the GPG key that seals etcd), `certs/`, `.lego/` and
`backups/`. That keeps backups interchangeable between the two hosts.

## Network boot

The host is also the homelab's PXE server, so a blank or wiped machine
boots straight into Talos and shows up in Omni in maintenance mode. No USB
stick is needed.

```
UEFI PXE ──DHCP (UniFi: next-server = Omni host, file ipxe.efi)
         ──TFTP ipxe.efi ── iPXE, embedded script: dhcp, chain boot.ipxe
         ──TFTP boot.ipxe ── menu ── HTTPS pxe.factory.talos.dev (kernel, initramfs)
         ──Talos maintenance mode ── SideroLink ── Omni
```

- **DHCP stays on UniFi.** The host only answers TFTP (`pxe-tftp`:
  dnsmasq with `--port=0` and no DHCP range). It uses `--tftp-single-port`
  so the whole transfer stays on 69/udp, which is the only port the firewall
  opens for it.
- **`ipxe.efi`** is iPXE's `snponly.efi`, built from a pinned commit
  (v2.0.0, `pxe/build-ipxe.sh`) in the pinned Debian image from
  `versions.yaml`, with HTTPS on and `pxe/embed.ipxe` embedded. The embedded
  script is what makes this work with UniFi. UniFi can't give iPXE a
  different filename from the firmware, so a stock iPXE would chainload
  `ipxe.efi` forever. This one runs `dhcp` and then chains `boot.ipxe` from
  the same server. The host builds it itself on first boot (`pxe-setup`,
  a few minutes) into `/var/lib/omni/tftp`, and rebuilds only when its
  inputs change. The binary doesn't fit in the ISO's 256 KiB embedded
  Ignition.
- **`boot.ipxe`** is the menu: Talos (`iscsi-tools`, `util-linux-tools`,
  the default after 15 s), Talos for GPU nodes (plus the NVIDIA driver and
  container toolkit, which Talos needs baked in as system extensions because
  it is immutable; the GPU operator then runs on top with its own driver and
  toolkit disabled), local disk, and iPXE's command line (the bootloader's
  prompt for troubleshooting a failed boot; Talos itself has no shell). It
  picks `amd64`/`arm64` at boot.

  **The host builds the menu itself.** `pxe-menu.timer` (at boot and daily)
  uses an Omni service account to (re)create two installation-media
  presets in its own Omni: `homelab-talos` with `PXE_EXTENSIONS`, and
  `homelab-talos-nvidia` adding `PXE_GPU_EXTENSIONS` (`host.env`; mirror
  `terraform/omni/locals.tf`). It then fills their Image Factory PXE URLs
  into the template and installs the menu in the TFTP root. Since Omni 1.14
  the join configuration is embedded in the schematic. The presets follow
  Omni's default Talos version, so the network image stays current with no
  manual step. Machines that join the cluster get the cluster's Talos
  version installed anyway. `omnictl` comes from Sidero's release matching
  the running Omni, checked against its `sha256sum.txt`.

  **The filled-in menu never goes into git:** anyone can read a schematic at
  `factory.talos.dev/schematics/<id>`, and Omni's schematics embed its join
  token. The repo holds only the template (`pxe/boot.ipxe.tmpl`, no URLs),
  and the menu lives on `omni-data`.

  One-time setup, with `omnictl` logged in to this Omni:

  ```bash
  SOPS_AGE_KEY_FILE=~/Projects/homelab/.agekey omni-server/coreos/pxe/set-service-account.sh
  ```

  This creates the `pxe-menu` service account and stores its key in
  `secrets.sops.yaml`. Commit that, then reinstall. Omni caps keys at a year,
  so `pxe-menu` renews its own key every 30 days and keeps the current one on
  `omni-data` (kept across reinstalls, included in backups). The key in SOPS
  only bootstraps; there's no yearly chore. The account has the Admin role
  so it can renew itself. That adds no real exposure, since root on the Omni
  host controls Omni anyway. Until a key is set, the menu says so and falls
  back to the local disk.
- **HTTPS trust:** iPXE is built with the Mozilla roots from the pinned
  Debian image's `ca-certificates` embedded and trusted (`TRUST=`/`CERT=`).
  iPXE's default trust is only its own root, which reaches public CAs
  through cross-signed certificates fetched from `ca.ipxe.org` over plain
  HTTP. That default **rejected** `pxe.factory.talos.dev` ("Permission
  denied", ipxe.org/0216eb8f; chain ZeroSSL → Sectigo R46 → USERTrust RSA).

**UniFi (you):** Settings → Networks → the 10.1.10.0/24 network → DHCP →
Network Boot: server `10.1.10.88` (the Omni host), filename `ipxe.efi`.

**Each machine's firmware (you):**

- UEFI boot mode with the UEFI network stack and IPv4 PXE enabled (often
  "Network Stack" plus "IPv4 PXE Support" on the boot or advanced page).
- Boot order: local disk first, then network. An installed machine boots
  its disk; a blank or wiped one falls through to PXE. With network first,
  every restart would boot the network image instead of the installed
  system.
- Secure Boot off. To keep it on, create the presets with `--secureboot`
  and enroll Sidero's keys; iPXE itself would also need a signed build,
  which this setup doesn't provide.

## Bootstrap a new host

Needs `butane`, `sops` (with the age identity), `envsubst` (gettext) and
Docker for coreos-installer.

1. Create the secrets once (from the repo root, so `.sops.yaml` applies):

   ```bash
   cp omni-server/coreos/secrets.example.yaml omni-server/coreos/secrets.sops.yaml
   $EDITOR omni-server/coreos/secrets.sops.yaml
   sops --encrypt --in-place omni-server/coreos/secrets.sops.yaml
   ```

   Set the Dex break-glass password with
   `SOPS_AGE_KEY_FILE=~/Projects/homelab/.agekey ./set-dex-password.sh`
   (prompts; stores the bcrypt hash and the plaintext).
   For a migration, copy `DEX_OMNI_CLIENT_SECRET` and the
   `DEX_ADMIN_PASSWORD_HASH` from the old host's `.env`. This keeps the
   break-glass password. The client secret could just as well be new.
   `omni_data_luks_key` must never change once a host uses it.

2. Check `host.env`. `INSTALL_DEVICE` must be the target disk as the live ISO
   sees it (`lsblk`). `OMNI_LAN_IP` is the address machines' WireGuard
   endpoint uses; keep 10.1.10.88 when replacing the current host.

3. Build the install ISO and boot the machine from it, following
   [Build the install ISO](INSTALL-ISO.md):

   ```bash
   cd omni-server/coreos
   SOPS_AGE_KEY_FILE=~/Projects/homelab/.agekey make iso   # build/omni-install.iso
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
`host.env` or the secrets, then build and boot a new ISO
([guide](INSTALL-ISO.md)). The installer keeps
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
  the new images first. Flux writes `tag@digest` (the ImagePolicies set
  `digestReflectionPolicy`); a tag-only ref, if one appears, gets resolved
  to a digest and pinned. It takes a `pre-upgrade` backup,
  rewrites `/etc/omni/images.env` (keeping `images.env.prev`) and restarts
  the changed services. Then it waits for `https://<omni>/healthz` and
  `https://<dex>:5556/healthz`.
- There is no automatic rollback: Omni migrates its
  databases on start. To go back, copy `images.env.prev` over `images.env`
  and `omni-restore` the `pre-upgrade` archive.

Order still matters for Talos and Kubernetes:
[Upgrades](https://github.com/isaiah-harville/homelab/blob/main/docs/operations/upgrades.md). Upgrade `omnictl` alongside.

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

## Migration from the Compose host (done 2026-11-25)

Kept as a record, and for restoring an old Compose-era archive.


1. Pin `versions.yaml` to the version the old host runs (they share Flux's
   bumps, so normally nothing to do).
2. Create `secrets.sops.yaml` (above), reusing the old `.env` values if you
   want the same admin password.
3. On the old host: `sudo systemctl start omni-backup`, then copy the newest
   archive off it. `backups/` is root-only, so stage it in your home first
   (the names sort by time):

   ```bash
   ssh -t isaiah@10.1.10.88 'sudo install -m 0600 -o isaiah "$(sudo find /home/isaiah/homelab/omni-server/backups -name "omni-*.tar.gz.age" | sort | tail -1)" ~/'
   scp 'isaiah@10.1.10.88:omni-*.tar.gz.age' ~/Projects/homelab/
   ```

   Then stop the stack (`docker compose down`). From here, management is
   down until step 5; the cluster keeps running.
4. Install the new host on the same IP (10.1.10.88) and hostnames, so
   machines' SideroLink endpoint and DNS stay valid. On the same hardware
   the install wipes the Ubuntu disk, so check you have the archive first.
5. Restore: `age -d -i <identity> omni-<stamp>.tar.gz.age | ssh core@<host>
   sudo omni-restore -`. Machines reconnect over SideroLink within a minute
   or two; check `omnictl get links`.
6. Retire the Compose files (done: `compose.yaml`, `dex.yaml` and
   `.env.example` are gone; Flux's setters now only touch `versions.yaml`).

## Validation

Done in QEMU on an Apple Silicon Mac (aarch64 FCOS and Talos, HVF,
swtpm vTPM). Nothing touched the production host or cluster. The QEMU
harness has since been removed from the repo; it is in git history as
`omni-server/coreos/test/` (commit 819c1aa) if a change to storage,
encryption or Ignition needs testing again before a production reinstall.

Each step ran against the real `omni.bu`, with test-only differences:
- a `.test` domain with a throwaway CA and pre-seeded certificate;
- the machine API over plain `grpc://`, since Talos in maintenance mode
  can't trust a private CA;
- an initial service account for `omnictl`;
- Zincati held until its own step;
- throwaway age-encrypted secrets.

"Marker" means an Omni user created before the step, and a joined Talos VM
whose SideroLink `Link` had to come back as `connected: true`.

| Step | Result |
|------|--------|
| Install from the auto-installing ISO (FCOS 44.20261023.3.1) | Root and `omni-data` encrypted. `/var/lib/omni` mounted. GPG key and tools image created. Dex, then Omni, healthy |
| Talos VM joins over SideroLink (Talos 1.13.12) | `Link` connected, machine in maintenance mode |
| Reboot | New boot ID, healthy, marker user and Talos link intact |
| Reinstall from the ISO, keeping `omni-data` | Installer saved partition 5. Ignition reused partition, LUKS and XFS. Same GPG key, marker user present, Talos reconnected |
| Zincati update 44.20261023.3.1 to 45.20261030.3.1 (latest stable) | Staged, rebooted, healthy, state intact. The production window then parsed as "next window at 4:30 on Sun (UTC)" |
| `omni-sync` patch upgrade, Omni v1.13.2 to v1.13.3 | Tag-only ref resolved and pinned by digest, `pre-upgrade` backup written, Omni restarted, both `/healthz` OK; second run "up to date" |
| `omni-sync` minor upgrade to v1.14.0 (the repo's real `versions.yaml`) | Same, Omni reports `backendversion: v1.14.0`, state intact |
| Restore an archive made by the Compose host's backup script (the former playbook's `omni-backup.sh.j2`, rendered unchanged, run against a Compose stack of Omni 1.14.0) | `omni-restore -` brought up the old instance on FCOS. Its users and GPG key, Omni 1.14.0 healthy on the restored etcd |
| FCOS `omni-backup` + `omni-restore -i` round trip | Same top-level layout and `.env` format as the Compose host's archive. A user created after the backup was gone after the restore |
| Talos 1.14.7 (latest) joins the restored instance | Connected |
| lego against a local Pebble ACME server (in place of Let's Encrypt + Cloudflare) | Certificate issued into `.lego/`. `omni-cert-deploy` installed it (key `root:1001 0640`) and restarted Dex and Omni |
| Firewall | 5556 and 8090 reachable from the allowed CIDR; 10000 and 2122 dropped (time out). Omni 1.14 binds metrics to loopback and nothing on 10000 |
| Network boot: host side (reinstall on FCOS 45) | `pxe-setup` built `ipxe.efi` on first boot from the pinned iPXE commit. `pxe-tftp` (dnsmasq, DNS off, single port) served `ipxe.efi` and `boot.ipxe` to a TFTP client through the firewall. a script created both presets and generated the menu (now `pxe-menu` on the host does this) |
| Network boot: blank UEFI VM, empty disk | Firmware PXE → `ipxe.efi` → embedded `dhcp` → `tftp://<server>/boot.ipxe` → menu (default entry) → HTTPS Image Factory → Talos 1.14.7 with `iscsi-tools` + `util-linux-tools` in Omni, connected, maintenance mode. The NVIDIA entry's URL was generated but not booted (no GPU in the lab) |

The Mac can't bind 69/udp without root, so in the boot test QEMU's own
DHCP/TFTP handed the VM the `ipxe.efi` and `boot.ipxe` just fetched from
the host's TFTP server (byte-identical). The host's TFTP serving was
checked separately with a real TFTP client. In production the machines
talk to the host directly; UniFi's DHCP is the only piece the lab didn't
exercise.

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
- **The production host is a laptop run with its lid closed.** CoreOS's
  logind would suspend it on boot. Found on the real host, not in the VMs:
  the lid handling there was a hand edit the playbook never recorded.
- **Certificate issuance needs public DNS for its checks.** On the real
  host, lego created its Cloudflare challenge record but waited for it
  through the LAN's split-horizon DNS, which answers `int.harville.dev`
  itself, and timed out. `--dns.resolvers 1.1.1.1:53` fixes it (tested
  against Let's Encrypt staging on the host). The VM tests used a local CA,
  so they couldn't catch this.
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

- **The ISO's embedded Ignition is capped at 256 KiB (compressed).** A
  1.1 MB `ipxe.efi` can't ride along, and even the 300 KB `snponly.efi`
  would sit at the limit. So the host builds iPXE itself from pinned
  inputs, once, onto `omni-data`.
- **iPXE's default HTTPS trust rejected the Image Factory** (see Network
  boot): the build embeds the Mozilla roots instead.
- **A failing `iseq` ends an iPXE script** unless followed by `||`. The
  menu's first version aborted on "Result too large" (ipxe.org/46022085).

Test-environment only (no change to the host config):

- Omni needs SNI: clients must use its hostname, not an IP.
- Talos in maintenance mode can't trust a private CA. For a plaintext
  machine API, the SideroLink URL must be `grpc://`: Talos still tries TLS
  with the `http://` URL Omni advertises when it has no machine-API cert.
  Production uses Let's Encrypt, so it is unaffected.
- QEMU's user network offers IPv6, so iPXE preferred the factory's AAAA
  record, and the Mac had no IPv6 route out ("Network unreachable"). The
  PXE VM runs with `ipv6=off`. On the LAN this only matters if machines get
  IPv6 addresses without IPv6 connectivity.
- On Apple Silicon (HVF) QEMU's TPM needs `ppi=off`. A UEFI-booted Talos VM
  needs `virtio-rng-pci`, or it blocks on entropy. Direct kernel boot has
  no SMBIOS, so Talos never registers.

## The production host

- A Dell Latitude 5521 (x86_64, one 512 GB NVMe, TPM 2.0, UEFI with Secure
  Boot off) that runs with its **lid closed**. `INSTALL_DEVICE=/dev/nvme0n1`.
  The config ignores the lid switch and masks the sleep targets. Open the lid
  while the installer runs (the live ISO would suspend) and to reach the boot
  menu (F12).
- It gets 10.1.10.88 from UniFi DHCP on its wired NIC (`enp0s31f6`); keep
  that a fixed IP in UniFi.
- `secrets.sops.yaml` reuses cert-manager's Cloudflare token. It holds the
  Dex client secret, the `omni-data` LUKS key, the break-glass password
  (`sops -d --extract '["stringData"]["dex_admin_password"]' ...`, set with
  `set-dex-password.sh`) and the `pxe-menu` bootstrap key.
- Network boot is live once UniFi's Network Boot points at the host and each
  machine's firmware is set as described under Network boot.
