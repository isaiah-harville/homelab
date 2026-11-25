# Self-hosted Omni

The Talos management plane for the homelab cluster. It runs **outside** the
cluster, on its own host, so it survives a full node wipe. Omni manages
cluster lifecycle; Talos provides the control-plane VIP.

**The host** is Fedora CoreOS at 10.1.10.88 (`omni.int.harville.dev`, Dex at
`omni-dex.int.harville.dev`; DNS is split-horizon), built from one Butane
file in [`coreos/`](coreos/README.md). That README covers how the host works,
upgrades, backups and restore, network boot and the findings behind it.
[Build the install ISO](coreos/INSTALL-ISO.md) is the step-by-step for
installing or changing it. Omni and Dex run there as Docker containers. A Docker
Compose stack on Ubuntu, configured by an Ansible playbook, ran Omni until
the cutover on 2026-11-25; both are gone from the repo.

Authentik deliberately does not front Omni or Dex: logging in must keep working
when the cluster is down. Dex's static `admin@int.harville.dev` account is the
break-glass login; its password is in `coreos/secrets.sops.yaml`
(`dex_admin_password`).

## Ports

All allowed from 10.1.0.0/16 only (nftables on the host); everything else,
including Omni's metrics on 2122, is closed to the LAN.

| Port  | Purpose                        |
|-------|--------------------------------|
| 443   | Omni UI / API                  |
| 8090  | Machine API (SideroLink setup) |
| 8100  | Kubernetes API proxy           |
| 5556  | Dex OIDC                       |
| 50180/udp | SideroLink WireGuard       |
| 69/udp | TFTP for network boot         |

The event sink (8091) and machine logs (8092) travel inside the SideroLink
tunnel.

## omnictl

```bash
omnictl get machines        # logs in through Dex in the browser the first time
```

Upgrade `omnictl` alongside Omni; an older client is refused once the API
version moves. CI's Terraform uses the `terraform` service account
(`omni-terraform` Secret), and the host's network-boot menu uses
`pxe-menu`. Both renew their own keys.

## Machine logs after a crash

Omni stores each machine's kernel log, streamed over SideroLink, in its
SQLite database (`/var/lib/omni/data/omni.db`). It keeps up to 200,000 lines
per machine for 30 days, which covers several weeks at normal volume. To read
what a node logged before it reset:

```bash
omnictl machine-logs <machine-id> | grep -B200 '"seq":0,'
```

`seq` restarts at 0 on each boot, so the lines just before a `"seq":0` entry
are the last ones the previous boot sent. A hard panic can stop the stream
before the panic text is sent.

## Backups

There are two kinds, and they cover different things:

- **Host state, weekly:** Omni's databases, the GPG key that seals etcd,
  TLS and secrets. `omni-backup.timer` on the host writes an age-encrypted
  archive. See [CoreOS host → Backups and restore](coreos/README.md#backups-and-restore).
- **etcd → S3 (SeaweedFS), automatic:** Omni's own snapshots of the
  cluster's etcd, described below.

### etcd → S3 (SeaweedFS)

Omni runs with `--etcd-backup-s3`. The bucket and credentials come from an
`EtcdBackupS3Configs` resource, and the schedule from the cluster's
`backupConfiguration` (set in `terraform/omni/cluster.tf`, mirrored in
`talos/omni/cluster-template.yaml`):

```bash
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

The `omni-backup` SeaweedFS identity (scoped to `Read/Write/List/Tagging` on
the `backups` bucket only) lives in
`apps/seaweedfs/seaweedfs/app/seaweedfs-s3-config.sops.yaml`. Backups land
under `s3://backups/omni/...`; list them with
`omnictl etcd-backup list --cluster homelab` (or the Omni UI's Backups tab).

**Restore:** `omnictl cluster template sync` a template with the target
cluster's `id` sourced from the backup, or use the Omni UI's "Restore from
backup" when creating or re-pointing a cluster. This only restores Omni's
view of cluster and machine state; Talos itself is unaffected.
