# Books and Kindle delivery

Shelfmark is exposed at `https://books.harville.dev` for book discovery and
download. Calibre-Web-Automated (CWA) is the internal library and delivery
service at `https://calibre.int.harville.dev`.

Shelfmark writes completed downloads into CWA's ingest directory. CWA imports
them into the Calibre library and, once a Kindle address is configured, can
automatically email the best available format to that Kindle.

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
5. Copy the Cloudflare SMTP token directly from the pod to the local clipboard:

   ```bash
   kubectl -n apps exec deploy/books -c calibre-web-automated -- \
     sh -c 'cat /run/secrets/books-smtp/cloudflare-smtp-token' | pbcopy
   ```

   Paste it into CWA's email-server settings without writing it to a file.
6. Configure CWA's outbound mail settings:

   | Setting | Value |
   | --- | --- |
   | SMTP host | `smtp.mx.cloudflare.net` |
   | SMTP port | `465` |
   | Encryption | SSL / implicit TLS |
   | Username | `api_token` |
   | Password | Cloudflare token from the mounted Secret |
   | From address | `books@harville.dev` |

   Send a test message to a normal mailbox before enabling Kindle delivery.
7. Leave the Kindle delivery address empty until it is known. When available,
   add it to the intended CWA user's profile and enable automatic send for that
   user. In Amazon's Personal Document Settings, approve
   `books@harville.dev` as a sender.
8. Test with a public-domain EPUB: download it in Shelfmark, confirm it appears
   in CWA, and then confirm delivery after the Kindle address is configured.

## Operational constraints

Cloudflare Email Service limits the complete SMTP message, including MIME
encoding and headers, to 5 MiB. Larger ebooks will not deliver through this SMTP
path even when their source file is slightly smaller than 5 MiB. Check CWA's
task log when an import succeeds but Kindle delivery does not.

The `books-oidc` and `books-smtp` Kubernetes Secrets are SOPS/age encrypted in
Git. Changes to either Secret roll the consumers through the encrypted file's
SOPS MAC. CWA does not accept SMTP configuration through environment variables,
so SMTP is the only intentional one-time UI configuration.

The Kindle address is user data stored in CWA and is deliberately absent from
Git until it is known.
