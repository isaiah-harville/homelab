# Inquizitive

[Inquizitive](https://github.com/isaiah-harville/inquizitive) is an open-source
flashcard and spaced-repetition app. It runs at
`https://inquizitive.harville.dev` from its published Helm chart
(`oci://ghcr.io/isaiah-harville/charts/inquizitive`, `HelmRepository`
`inquizitive`).

## Shape

- One replica. SQLite and card images live on a 5 GiB `longhorn-retain`
  volume, so the default Longhorn recurring jobs snapshot both together.
- Public route on `traefik-public` with **no ForwardAuth**. The app signs people
  in itself through Authentik (public OIDC client `inquizitive`, PKCE), because
  the desktop app syncs with bearer tokens that can't follow a browser redirect.
- Members of **Inquizitive Users** or **authentik Admins** can sign in. Admins
  get the in-app admin role from the `groups` claim.

## Desktop sync

Sign in on the web, open **Settings → Desktop sync**, create a token, and paste
it with `https://inquizitive.harville.dev` into the desktop app's
**Settings → Sync with a server**. Revoke tokens on the same page.

## Moving to PostgreSQL

The chart takes a CloudNativePG secret with `database.existingSecret:
<cluster>-app` and `database.existingSecretKey: uri`. Add `inquizitive` to the
`config-backup-s3` reflection list first so the cluster can archive to
SeaweedFS like the other app databases, then export a backup from the app
(Settings → Backup & export) and import it after switching.
