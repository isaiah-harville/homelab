# qBittorrent with NordVPN Design

## Goal

Deploy qBittorrent in the homelab and connect it to Shelfmark so a Books user
can select a torrent result and have the completed book imported into
Calibre-Web-Automated (CWA). All BitTorrent traffic must use NordVPN, and a VPN
failure must block torrent egress without taking CWA or Shelfmark offline.

The qBittorrent Web UI will be available only on the internal route
`https://torrent.int.harville.dev` behind Authentik. This change creates no new
Authentik group.

## Architecture

A new `qbittorrent` Deployment in the `apps` namespace will contain Gluetun and
qBittorrent. The two containers share one Kubernetes pod network namespace, so
Gluetun can enforce its firewall and route qBittorrent through NordVPN.

Gluetun will run as a native Kubernetes sidecar init container with
`restartPolicy: Always`. Its startup probe must pass before Kubernetes starts
qBittorrent. This ordering prevents qBittorrent from opening network connections
before the VPN firewall is active.

The existing Books Deployment remains separate. A NordVPN or qBittorrent outage
therefore makes torrent downloads unavailable but does not interrupt the CWA or
Shelfmark web applications.

Both the Books and qBittorrent Deployments will use required node affinity to
exclude `talos-rwj-wvp`, the frequently unavailable DL380.

## VPN and Network Boundary

Gluetun will use these non-secret settings:

- `VPN_SERVICE_PROVIDER=nordvpn`
- `VPN_TYPE=openvpn`
- `OPENVPN_PROTOCOL=udp`
- `SERVER_COUNTRIES=United States`
- `TZ=America/Chicago`

The NordVPN manual-setup service username and password will be read from a
SOPS-encrypted Kubernetes Secret. The specification and unencrypted manifests
must not contain either credential.

Gluetun receives only the capabilities and device access it requires:

- Linux capability `NET_ADMIN`;
- `/dev/net/tun` mounted from the Talos node; and
- an `emptyDir` working directory at `/gluetun`.

Its firewall permits the qBittorrent Web UI/API port from the cluster network.
All peer, tracker, and DNS traffic originating from qBittorrent otherwise leaves
through the NordVPN tunnel. If the tunnel is unavailable, Gluetun's firewall
remains the kill switch and blocks direct Internet egress.

Talos enforces Pod Security baseline in the `apps` namespace, which rejects
`NET_ADMIN`. The namespace will therefore be labeled with Pod Security
`privileged` enforcement, audit, and warning levels. Only Gluetun declares the
extra capability; the label does not add capabilities to other containers.

## Storage and Paths

The deployment adds two PVCs:

- `qbittorrent-config`: 2 GiB, `ReadWriteOnce`, `longhorn-retain`, mounted at
  `/config` by qBittorrent.
- `qbittorrent-downloads`: 50 GiB, `ReadWriteMany`, Longhorn, mounted at
  `/data/torrents` by qBittorrent and Shelfmark.

Shelfmark and qBittorrent must see the identical `/data/torrents` container path.
This follows Shelfmark's supported shared-filesystem integration and avoids a
remote path mapping.

The existing CWA ingest and library volumes are unchanged. Shelfmark copies a
successfully processed ebook from the torrent volume into `/books`, which is the
existing CWA ingest volume.

## qBittorrent Configuration and Credentials

The qBittorrent container will use a stable version range or image policy rather
than an unbounded `latest` deployment. It runs as UID/GID 1000 and stores its
configuration on the retained config PVC.

A generated qBittorrent Web UI username and password will be stored in the same
SOPS-encrypted application Secret as the NordVPN credentials. Shelfmark reads
the qBittorrent credentials from that Secret. The Web UI password will be
written to qBittorrent's configuration as its supported PBKDF2 representation;
both the plaintext password and its generated hash remain only in the encrypted
Secret.

The bootstrap is idempotent: it creates the initial qBittorrent configuration
when missing, preserves runtime state across pod replacements, and reapplies
only security- and integration-critical values when the Secret changes. The
Secret's SOPS MAC will be copied into both Deployments' pod-template annotations
so credential changes roll the relevant pods.

The Web UI listens on port 8080. UPnP and NAT-PMP are disabled because the pod is
behind NordVPN and must not attempt to modify LAN router mappings.

## Shelfmark Integration and Data Lifecycle

Shelfmark will receive these settings:

- `PROWLARR_TORRENT_CLIENT=qbittorrent`
- `QBITTORRENT_URL=http://qbittorrent.apps.svc:8080`
- `QBITTORRENT_USERNAME` and `QBITTORRENT_PASSWORD` from the encrypted Secret
- `QBITTORRENT_CATEGORY=books`
- `QBITTORRENT_DOWNLOAD_DIR=/data/torrents`
- `PROWLARR_TORRENT_ACTION=change_category`
- `PROWLARR_TORRENT_POST_IMPORT_CATEGORY=imported`

Shelfmark changes a torrent to the `imported` category only after successful
post-processing and transfer to CWA's ingest directory. Failed, incomplete, or
unprocessed torrents retain their original category and are excluded from
automatic deletion.

A daily CronJob authenticates to qBittorrent's internal Web API and selects only
torrents that meet both conditions:

1. category is exactly `imported`; and
2. completion time is at least 24 hours old.

It removes each selected torrent and its downloaded files. The imported copy in
CWA's ingest or library storage is unaffected. Cleanup is idempotent and treats
an already-removed torrent as success.

## Internal Web UI and Authentik

A ClusterIP Service exposes qBittorrent port 8080. An Ingress uses
`traefik-internal`, the shared wildcard certificate, and host
`torrent.int.harville.dev`.

The Ingress uses the existing Authentik ForwardAuth middleware. The Authentik
blueprint will create the application/provider records and initially bind the
existing `authentik Admins` group. It will not create a qBittorrent-specific
group. An additional existing group may be bound later without changing the
qBittorrent deployment.

qBittorrent's native credentials remain enabled as defense in depth and for
direct cluster-internal API access by Shelfmark and the cleanup job.

## Failure Handling

- **NordVPN unavailable:** Gluetun remains unready and its firewall blocks direct
  torrent egress. CWA and Shelfmark remain available.
- **qBittorrent unavailable:** Shelfmark reports the download-client failure and
  does not delete or mark source data as imported.
- **Shelfmark import fails:** the torrent stays in `books`; automated cleanup
  does not touch it.
- **DL380 unavailable:** scheduler affinity keeps both Deployments on other
  nodes. Longhorn handles volume reattachment after node failure.
- **Credential rotation:** changing and re-encrypting the Secret changes its
  SOPS MAC, which rolls both consumers.
- **Cleanup API failure:** the CronJob exits non-zero and retries on its next
  schedule; it does not perform filesystem deletion independently of qBittorrent.

## Validation and Acceptance

Repository validation will verify that:

- the Books and qBittorrent Deployments exclude `talos-rwj-wvp`;
- only Gluetun requests `NET_ADMIN` and `/dev/net/tun`;
- the `apps` namespace has the required Pod Security labels;
- both applications mount the same RWX volume at `/data/torrents`;
- Shelfmark uses the internal qBittorrent Service and encrypted credentials;
- the internal Ingress uses Authentik ForwardAuth and
  `torrent.int.harville.dev`;
- the cleanup job requires both the `imported` category and a 24-hour age;
- no plaintext credential appears outside a SOPS-encrypted manifest; and
- all Kustomize renders and repository pre-commit checks pass.

After Flux reconciliation, live acceptance is:

1. Books remains Ready while qBittorrent rolls or the VPN is unavailable.
2. Gluetun reports a healthy NordVPN United States tunnel.
3. The public IP observed from the qBittorrent pod differs from the normal
   homelab egress IP.
4. `torrent.int.harville.dev` redirects unauthenticated requests to Authentik
   and permits the configured Authentik policy.
5. Shelfmark's qBittorrent client check succeeds.
6. A controlled download completes, is copied into CWA ingest, and changes to
   the `imported` category.
7. Cleanup dry-run selection includes only imported torrents older than 24
   hours; the destructive cleanup path is not tested against unrelated data.

## Upstream References

- Gluetun NordVPN provider configuration:
  <https://github.com/qdm12/gluetun-wiki/blob/main/setup/providers/nordvpn.md>
- Gluetun firewall and Kubernetes sidecar support:
  <https://github.com/qdm12/gluetun>
- LinuxServer qBittorrent container configuration:
  <https://docs.linuxserver.io/images/docker-qbittorrent/>
- Shelfmark shared download path and torrent settings:
  <https://github.com/Calibrain/Shelfmark/blob/main/docs/configuration.md>
