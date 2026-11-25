# Build and use the Omni install ISO

The Omni host is installed from a USB stick that carries everything: Fedora
CoreOS plus the host's own config (`omni.bu` rendered with `host.env`,
`versions.yaml` and the decrypted `secrets.sops.yaml`). Booting it wipes the
install disk, except the `omni-data` partition, installs and reboots, with
no questions asked.

Build a new ISO for:

- the first install, or the cutover from the Compose host;
- any change to the host itself: `omni.bu`, `files/`, `host.env`, the
  secrets, or the network-boot inputs in `pxe/`;
- recovering a broken host (Omni's state survives on `omni-data`).

You don't need one for Omni or Dex version bumps: `omni-sync` applies those
from `versions.yaml`. Nor for OS updates (Zincati) or boot-menu changes
(`pxe/presets.sh` installs the menu over SSH).

## 1. Prerequisites (once, on the Mac)

```bash
brew install butane sops gettext jq   # gettext provides envsubst
```

Docker Desktop must be running (coreos-installer runs in a container). The
age identity is `~/Projects/homelab/.agekey`; worktrees don't have a copy.

## 2. Check the inputs

Build from an up-to-date `main` in the main checkout, so the ISO matches what
the host will sync from:

```bash
cd ~/Projects/homelab && git switch main && git pull
cd omni-server/coreos
./check.sh                         # the same static checks CI runs
```

Then confirm:

- `host.env`: `INSTALL_DEVICE` is the disk to install to (`/dev/nvme0n1` on
  the current Latitude). `OMNI_LAN_IP` is the address machines reach Omni
  on; UniFi must hand the host that address (a fixed IP for its MAC).
- `versions.yaml`: the Omni version. When restoring a backup, it must match
  the version the backup came from.
- `secrets.sops.yaml`: change the Dex break-glass password with
  `SOPS_AGE_KEY_FILE=~/Projects/homelab/.agekey ./set-dex-password.sh`.
  Never change `omni_data_luks_key` on an existing host: a reinstall with a
  different key can't open the kept data.

## 3. Build

```bash
SOPS_AGE_KEY_FILE=~/Projects/homelab/.agekey make iso
```

This renders `build/omni.ign` (`render.sh`, `butane --strict`), downloads
the stable x86_64 FCOS live ISO once and checks its signature. It then
writes `build/omni-install.iso` with the config embedded. After the first
download it takes seconds.

The downloaded FCOS ISO is cached as `build/fedora-coreos-live.x86_64.iso`.
Delete it to pick up a newer FCOS release; otherwise Zincati updates the
host to the latest within a week of installing anyway.

To see what's inside without printing secrets:

```bash
docker run --rm -v "$PWD/build:/data:ro" quay.io/coreos/coreos-installer:release \
  iso ignition show /data/omni-install.iso | jq '[.storage.files[].path]'
# ["/etc/coreos/installer.d/0000-installer.yaml", "/etc/coreos/dest.ign", ...]
```

**`build/omni-install.iso` contains the decrypted secrets** (Cloudflare token,
disk key, Dex secrets). Keep it off shared drives and delete it when done.

## 4. Write the USB stick

Find the stick and check it's the right disk: external, physical, the
expected size. `dd` overwrites whatever disk you name.

```bash
diskutil list external physical
diskutil unmountDisk /dev/diskN
sudo dd if=build/omni-install.iso of=/dev/rdiskN bs=4m status=progress
diskutil eject /dev/diskN
```

(balenaEtcher works too.)

## 5. Install

1. Open the laptop's lid. The installer would suspend on a closed lid, and
   you need the screen for the boot menu. The installed system ignores the
   lid.
2. Plug in the stick, power on and press **F12** for the one-time boot menu.
   Pick the USB stick under UEFI.
3. The installer runs on its own: about a minute writing the disk, then it
   reboots. **Pull the stick when it reboots**, or it installs again.
4. First boot takes a few minutes. Ignition partitions and encrypts the disk
   and reboots once more (to apply `selinux=0`). Then it creates the GPG key
   and certificate if `omni-data` has none, builds iPXE, pulls the images,
   and starts Dex and Omni.
5. Check it (SSH is `core@` with your `~/.ssh/id_ed25519` key; the host key
   is new):

   ```bash
   ssh-keygen -R 10.1.10.88
   ssh core@10.1.10.88 sudo omni-health
   ```

For the cutover or a recovery, restore Omni's state now
([README → Backups and restore](README.md#backups-and-restore)):

```bash
age -d -i ~/Projects/homelab/.agekey omni-<stamp>.tar.gz.age | ssh core@10.1.10.88 sudo omni-restore -
```

## 6. Clean up

```bash
rm -r build                                       # rendered secrets + ISO
diskutil eraseDisk FAT32 BLANK /dev/diskN         # the stick holds them too
```

## If it goes wrong

- **The host stops in an emergency shell on first boot:** Ignition failed.
  The console shows why (`journalctl -b` there). Common causes:
  - `INSTALL_DEVICE` names the wrong disk.
  - The TPM is off in the firmware: root encryption needs TPM 2.0.
  - `omni_data_luks_key` changed, so the kept data partition won't open.

  Fix the input, rebuild, and boot the stick again. A reinstall keeps
  `omni-data`.
- **It installs again after rebooting:** the stick was still in. Pull it;
  nothing is lost.
- **SSH refuses the key:** `ssh-keygen -R 10.1.10.88`. The host key is new
  on every install.
