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

## Adding someone

Every step is in Git or in the person's own accounts; nothing is configured in
CWA's or Shelfmark's admin pages.

1. **Give them access.** In Authentik, add them to the **Books Users** group.
2. **Have them sign in once** at `https://books.harville.dev`. Shelfmark creates
   their user on first login.
3. **Get their exact Shelfmark username.** In Shelfmark: Settings → Users. It is
   their Authentik username. It must match exactly (case does not matter): a
   typo means their books still reach the library but never their Kindle.
4. **Get their Kindle address.** On Amazon: Content & Devices → Devices → their
   Kindle → Email (ends in `@kindle.com`). The Kindle app on a phone has its own
   address under the same page.
5. **Approve the sender.** In *their* Amazon account: Content & Devices →
   Preferences → Personal Document Settings → Approved Personal Document E-mail
   List → add `books@harville.dev`. Amazon silently drops mail from any sender
   not on that list, so skipping this looks exactly like a delivery bug.
6. **Add them to the recipients secret** from the main checkout (worktrees have
   no `.agekey`):

   ```bash
   export SOPS_AGE_KEY_FILE=~/Projects/homelab/.agekey
   sops apps/media/books/app/kindle-recipients.sops.yaml
   ```

   `sops` opens the decrypted file in your editor and re-encrypts it on save.
   Add an entry to the `recipients.json` object. A value is one address or a
   list (for example a Kindle and the Kindle app):

   ```json
   {"anna": "anna_xyz@kindle.com", "sam": ["sam_1@kindle.com", "sam_2@kindle.com"]}
   ```

   The value must stay valid JSON. Before committing, check it still decrypts
   and parses:

   ```bash
   sops -d --extract '["stringData"]["recipients.json"]' \
     apps/media/books/app/kindle-recipients.sops.yaml | python3 -m json.tool
   ```

7. **Commit, open a PR and merge.** Flux applies the secret, Reloader restarts
   the books pod, and the initContainer creates their delivery user.
8. **Check it applied:**

   ```bash
   kubectl -n media logs deploy/books -c cwa-config
   ```

   expect `created delivery user <name> with auto-send on`. Then have them
   download a small public-domain book and confirm it arrives (CWA waits
   `auto_send_delay_minutes`, 5 by default, before sending).

To remove someone, delete their entry the same way. Their CWA user stays, with
no address and auto-send off.

## Troubleshooting delivery

- **`cwa-config` logged `ERROR: settings NOT applied`.** The script fails soft:
  it exits 0 so CWA and Shelfmark still start (they share the pod), and CWA
  keeps its previous settings. Common causes are invalid JSON in the recipients
  file or a CWA upgrade that changed `app.db`'s schema. Fix the cause and
  restart the pod: `kubectl -n media rollout restart deploy/books`.
- **The book is in the library but never arrived.** In CWA (Admin → Tasks),
  look for the auto-send task. "too large" means the file is over the 3.5 MiB
  cap. No task at all means the book was not in a folder named after a
  recipient: check `/cwa-book-ingest/` and the username in the recipients file.
  A task that succeeded with nothing on the Kindle almost always means
  `books@harville.dev` is not an approved sender in that Amazon account.
- **A setting changed in CWA's UI went back.** Expected: mail settings and
  eReader addresses are owned by Git and re-applied on every restart.

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
5. Add each reader as described in "Adding someone".

## Operational constraints

Cloudflare Email Service limits the complete SMTP message, including MIME
encoding and headers, to 5 MiB. Base64 adds about a third, so the initContainer
caps CWA's attachment size at 3.5 MiB; larger books import but are not sent.
Check CWA's task log when an import succeeds but Kindle delivery does not.

Shelfmark's download sources are IRCHighway `#ebooks` (IRC) and Prowlarr,
limited to the indexers that return ebooks (`PROWLARR_INDEXERS`, by Prowlarr
indexer ID; add an ID there when adding a book indexer). Anna's Archive (Direct
Download) is off: its search sits behind a DDoS-Guard challenge Shelfmark's
bypasser cannot solve.

Network exposure differs by source. Torrents go through qBittorrent, whose
traffic leaves through its gluetun NordVPN sidecar. IRC searches and DCC
transfers come from the Shelfmark container itself and leave from the home IP.
IRC transfers only download (they never upload), unlike torrents, which seed.

Shelfmark runs in Universal search mode with Hardcover as the metadata
provider, pinned by the `SEARCH_MODE` and `METADATA_PROVIDER` environment
variables. Searches query Hardcover first and look for releases only when a
user opens a book, so a slow or blocked release source no longer stalls the
search page. `RELEASE_SEARCH_TIMEOUT` caps one release search at 90 seconds
instead of the default 300. Environment values override the admin UI.

The `books-oidc`, `cloudflare-smtp` and `books-kindle-recipients` Secrets are
SOPS/age encrypted in Git; Kindle addresses are never committed in plain text.
