# Books and Kindle Delivery Design

## Goal

Deploy Shelfmark and Calibre-Web Automated (CWA) so an authorized user can open
`https://books.harville.dev`, sign in through Authentik with Google, search for
an ebook, select a release, and have the imported ebook sent automatically to a
configured Kindle address.

The public workflow must not require the user to visit or understand CWA. CWA's
administrative and library interface remains LAN-only at
`https://calibre.int.harville.dev`.

## Architecture

The stack is one Kubernetes `Deployment` in the `apps` namespace with two
containers:

- Shelfmark serves the public search and download UI on port 8084.
- CWA manages the library, repairs and converts EPUB files, and serves its
  internal UI on port 8083.

Both containers run in one pod and mount the same `ReadWriteOnce` ingest PVC.
This avoids a Longhorn RWX/NFS dependency and preserves local filesystem events:
Shelfmark writes a completed file to `/books`, and CWA sees the same file at
`/cwa-book-ingest`. The deployment uses the `Recreate` strategy because all
persistent volumes are RWO and only one stack replica is supported.

The data flow is:

1. The user signs in to Shelfmark through Authentik.
2. The user searches metadata and selects a release from an administrator-
   configured, legally authorized Shelfmark source.
3. Shelfmark downloads the complete file and moves it into the shared ingest
   directory.
4. CWA detects the completed file, runs its configured conversion and Kindle
   EPUB repair workflow, imports the result into its Calibre library, and removes
   the ingest copy.
5. CWA's auto-send job emails the preferred format to every CWA user with
   auto-send enabled and a configured eReader address. Initially this will be
   one recipient.

## Kubernetes Resources

Create a composite base at `apps/base/books/` containing focused manifests for:

- one `Deployment` with Shelfmark and CWA containers;
- one Shelfmark `Service` on port 8084;
- one CWA `Service` on port 8083;
- one public Shelfmark `Ingress` for `books.harville.dev` using
  `traefik-public`;
- one internal CWA `Ingress` for `calibre.int.harville.dev` using
  `traefik-internal` and Authentik ForwardAuth;
- four PVCs: CWA config (5 Gi), CWA library (50 Gi), CWA/Shelfmark ingest
  (10 Gi), and Shelfmark config (2 Gi);
- a Kustomization that applies the `apps` namespace.

The config, library, and Shelfmark config PVCs use `longhorn-retain`. The ingest
PVC is transient and uses `longhorn`. All PVCs use `ReadWriteOnce` because both
containers are co-located.

The deployment runs one replica and defines startup, readiness, and liveness
HTTP probes. Shelfmark uses `/api/health`; CWA uses its HTTP root because
upstream does not document a dedicated unauthenticated health endpoint. CPU and
memory requests are modest, while memory limits leave headroom for Calibre
conversion and Shelfmark browser automation.

Images start from the latest stable releases validated during implementation:
CWA 4.x and Shelfmark 1.x. Flux image policies admit stable updates inside those
major versions and exclude prereleases, matching the repository's existing
image automation pattern.

## Authentication and Authorization

Shelfmark uses native OIDC rather than Traefik ForwardAuth so it has an actual
user identity for roles, request history, and per-user settings. Its public
login automatically redirects to Authentik and disables local password login.
The callback is:

`https://books.harville.dev/api/auth/oidc/callback`

The Authentik blueprint creates:

- a confidential OAuth2/OIDC provider named `Shelfmark Provider`;
- an application with slug `books` and launch URL
  `https://books.harville.dev`;
- a `Books Users` group;
- policy bindings that permit `Books Users` and `authentik Admins`;
- standard `openid`, `email`, `profile`, and `groups` claims;
- a signing key so Shelfmark receives a valid JWKS document.
- a ForwardAuth proxy provider and `Calibre-Web Automated` application for
  `https://calibre.int.harville.dev`, permitted only to `authentik Admins` and
  added to the embedded outpost.

Shelfmark auto-provisions OIDC users. Membership in `authentik Admins` grants
Shelfmark administration; membership in `Books Users` grants ordinary access.
The homelab administrator must add the wife's Authentik account to `Books Users`
before first use.

CWA does not need a second OIDC client. Its LAN-only Ingress uses the existing
Authentik ForwardAuth middleware and the dedicated proxy application's policy,
then CWA's native admin session protects application-level administration. The
default CWA password must be changed during first-run setup.

## Secrets

The repository uses SOPS/age, not Bitnami Sealed Secrets. Two SOPS-encrypted
Secrets keep privileges separated:

- `books-oidc` contains a generated OIDC client ID and client secret. Authentik
  consumes it through `envFrom`, while Shelfmark receives only the individual
  OIDC keys it needs.
- `books-smtp` contains the supplied Cloudflare Email Service API token. It is
  mounted read-only in the CWA container and is never written in plaintext to
  Git, documentation, logs, or generated manifests.

CWA does not support configuring SMTP credentials from environment variables or
secret files. Therefore the Cloudflare token has a deliberate one-time setup
step: an administrator retrieves it from the Kubernetes Secret and enters it in
CWA's email-server settings. CWA then stores the credential encrypted in its
persistent application database. Automating direct SQLite mutation is rejected
because it depends on private upstream schema and encryption details.

Kustomize replacements copy the SOPS MACs to pod-template annotations so OIDC
secret rotation rolls Shelfmark and Authentik. SMTP secret rotation rolls the
books pod, but the new value must also be saved in CWA's email settings because
CWA cannot reload it from the mounted file.

## SMTP and Kindle Configuration

CWA is configured once with Cloudflare Email Service:

- Host: `smtp.mx.cloudflare.net`
- Port: `465`
- Encryption: implicit TLS/SSL
- Username: `api_token`
- Password: the value from `books-smtp`
- From address: `books@harville.dev`

The Kindle delivery address remains blank until it is found. When available, an
administrator adds it to the intended CWA user's eReader address field and
enables auto-send for that user. The sender address must also be added to the
Kindle account's approved personal-document senders.

Cloudflare SMTP has a hard 5 MiB message-size limit, including MIME overhead.
Books exceeding that limit fail in CWA's task history and require another
delivery path, such as Amazon's Send to Kindle web interface. This deployment
does not silently discard or mark failed sends as successful.

## Shelfmark Configuration

Environment variables provide stable deployment defaults:

- OIDC authentication with automatic redirect and auto-provisioning;
- secure cookies;
- `/books` as the destination directory;
- Universal search mode;
- `America/Chicago` timezone;
- library link to `https://calibre.int.harville.dev`;
- direct-download policy for authorized users, without an approval queue.

Shelfmark's persistent `/config` volume retains its database, cached artwork,
source configuration, and settings. Download sources are configured through the
Shelfmark UI after deployment. The GitOps manifests do not enable or encode any
third-party content source; the administrator is responsible for choosing
sources and material they are legally authorized to use.

## Failure Handling

- Shelfmark reports source and download failures in its activity UI and leaves
  no partial file in the CWA ingest directory.
- CWA records ingest, conversion, EPUB repair, and email-delivery work in its
  task history.
- If CWA is temporarily unavailable, Shelfmark's completed file remains on the
  shared ingest PVC and is processed after CWA recovers.
- If SMTP delivery fails, the imported library copy remains available in CWA for
  retry or manual download.
- Longhorn retains application configuration and the library across pod or node
  replacement. `longhorn-retain` also protects those PVCs from accidental claim
  deletion, but it is not an off-cluster backup.

## Validation

Static validation must pass:

```bash
kubectl kustomize clusters/homelab/apps >/dev/null
kubectl kustomize clusters/homelab/infra >/dev/null
uvx pre-commit run --all-files
```

Rendered-manifest checks must confirm:

- `books.harville.dev` routes only to Shelfmark through `traefik-public`;
- `calibre.int.harville.dev` routes only to CWA through `traefik-internal`;
- both containers mount the same ingest PVC at their upstream-required paths;
- the SMTP token is absent from rendered YAML and diffs;
- Shelfmark receives OIDC configuration from the encrypted Secret;
- secret MAC replacements annotate the intended workloads.

After Flux reconciles, operational acceptance is:

1. Authentik redirects an allowed Google-backed user to Shelfmark and denies a
   user outside `Books Users`.
2. Both health endpoints and Ingresses respond successfully.
3. A legally obtained public-domain EPUB selected in Shelfmark appears in the
   CWA library.
4. After the Kindle address is configured, the same workflow creates a
   successful CWA auto-send task and the book appears on the Kindle.

## Out of Scope

- Automatically discovering the Kindle delivery address.
- Configuring or operating torrent, Usenet, debrid, or VPN infrastructure.
- Enabling unverified third-party book sources in Git.
- Off-cluster Longhorn backups.
- Bypassing Cloudflare's 5 MiB SMTP limit.
