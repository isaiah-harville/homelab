# Books and Kindle delivery

Shelfmark is exposed at `https://books.harville.dev` for book discovery and
download. Calibre-Web-Automated (CWA) is the internal library and delivery
service at `https://calibre.int.harville.dev`.

Shelfmark writes each completed download into a per-user folder in CWA's ingest
directory (`/books/{User}` in Shelfmark, `/cwa-book-ingest/<user>/` in CWA).
CWA imports it into the Calibre library and emails it to that user's Kindle.
CWA only auto-sends a book from a user's folder to the CWA user of the same
name, so each person receives only the books they downloaded.

## Kindle delivery is managed in Git

CWA cannot read mail settings from the environment, so the `cwa-config`
initContainer (`app/scripts/cwa_config.py`) writes them into CWA's `app.db`
before CWA starts, on every pod start. Git wins: changes made in CWA's admin UI
to the mail server or to eReader addresses are reset on the next restart.

- **Mail server:** the `SMTP_*` env on the initContainer in
  `app/deployment.yaml` (Cloudflare Email, `books@harville.dev`). The password
  is the SOPS-encrypted `cloudflare-smtp` token, encrypted into `app.db` with
  CWA's own key.
- **Recipients:** `app/kindle-recipients.sops.yaml`, a JSON map from Shelfmark
  username to one address or a list of addresses. Each entry becomes a
  delivery-only CWA user (no roles, random password) with auto-send on. A user
  missing from the map gets no automatic delivery; their books still land in
  the library.

To add someone:

1. Find their Shelfmark username (Shelfmark admin → Users; it is their Authentik
   username).
2. From the main checkout:

   ```bash
   export SOPS_AGE_KEY_FILE=~/Projects/homelab/.agekey
   sops apps/media/books/app/kindle-recipients.sops.yaml
   ```

   and add `"username": "them@kindle.com"` (or a list) to `recipients.json`.
3. In their Amazon account, add `books@harville.dev` under Content & Devices →
   Preferences → Personal Document Settings → Approved Personal Document E-mail
   List. Amazon silently drops mail from any other sender.
4. Commit and merge. Reloader restarts the pod when the secret changes, and the
   initContainer applies it.

## First-run setup

1. In Authentik, add the intended user to **Books Users**. Authentik admins also
   retain access. Shelfmark automatically creates the local user at first login.
2. As an Authentik admin, sign in at `https://books.harville.dev` and configure
   only lawful, authorized content sources in Shelfmark's administration UI.
   Leave **Enable Requests** off; the deployment pins that setting off so regular
   users download directly instead of entering an approval queue.
3. Have the intended user sign in once and confirm a search result offers a
   direct download action.
4. From the LAN, open `https://calibre.int.harville.dev`, complete CWA's initial
   library setup, and change any bootstrap administrator password immediately.
5. Add the user to `kindle-recipients.sops.yaml` as described above, then test
   with a public-domain EPUB: download it in Shelfmark, confirm it appears in
   CWA, and confirm it reaches the Kindle.

## Operational constraints

Cloudflare Email Service limits the complete SMTP message, including MIME
encoding and headers, to 5 MiB. Base64 adds about a third, so the initContainer
caps CWA's attachment size at 3.5 MiB; larger books import but are not sent.
Check CWA's task log when an import succeeds but Kindle delivery does not.

Shelfmark's download sources are IRCHighway `#ebooks` (IRC) and Prowlarr,
limited to the indexers that return ebooks (`PROWLARR_INDEXERS`). Anna's
Archive (Direct Download) is off: its search sits behind a DDoS-Guard challenge
Shelfmark's bypasser cannot solve.

Shelfmark runs in Universal search mode with Hardcover as the metadata
provider, pinned by the `SEARCH_MODE` and `METADATA_PROVIDER` environment
variables. Searches query Hardcover first and look for releases only when a
user opens a book, so a slow or blocked release source no longer stalls the
search page. `RELEASE_SEARCH_TIMEOUT` caps one release search at 90 seconds
instead of the default 300. Environment values override the admin UI.

The `books-oidc`, `cloudflare-smtp` and `books-kindle-recipients` Secrets are
SOPS/age encrypted in Git; Kindle addresses are never committed in plain text.
