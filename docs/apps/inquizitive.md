# Inquizitive

[Inquizitive](https://github.com/isaiah-harville/inquizitive) is an open-source
flashcard and spaced-repetition app. It runs at
`https://quiz.harville.dev` from its published Helm chart
(`oci://ghcr.io/isaiah-harville/charts/inquizitive`, `HelmRepository`
`inquizitive`).

## Shape

- Two stateless replicas, spread across nodes. Sessions live in the database,
  so either replica serves any request.
- PostgreSQL from CloudNativePG (`inquizitive-postgres`, three instances,
  synchronous standby), archived to SeaweedFS through `config-backup-s3` with a
  nightly backup at 02:30. The app reads the `uri` key of `inquizitive-postgres-app`.
- Card images in the SeaweedFS bucket `inquizitive`, with an identity that can
  only touch that bucket (`inquizitive-s3`).
- Public route on `traefik-public` behind Authentik **ForwardAuth** (gate
  provider `inquizitive-gate`), and the app also signs people in itself through
  Authentik (public OIDC client `inquizitive`, PKCE). With an Authentik session
  the second sign-in is a single click.
- `/api/sync`, `/api/media` and `/api/health` have their own Ingress
  (`inquizitive-sync`) **without** ForwardAuth: the desktop app syncs with
  bearer tokens that can't follow a browser redirect. The app still requires a
  device token or app session there, and in OIDC mode it ignores proxy headers.
- Members of **Inquizitive Users** or **authentik Admins** pass both the gate and
  the app sign-in. Admins
  get the in-app admin role from the `groups` claim.

## Desktop sync

Sign in on the web, open **Settings → Desktop sync**, create a token, and paste
it with `https://quiz.harville.dev` into the desktop app's
**Settings → Sync with a server**. Revoke tokens on the same page.

## Restore

Rebuild the database from its archive the same way as `primer-postgres`: switch
`bootstrap` to `recovery` from `origin` and bump the archiving `serverName`.
People can also export their own library from Settings → Backup & export.
