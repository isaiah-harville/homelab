# Excalidraw

[ExcaliDash](https://github.com/ZimengXiong/ExcaliDash) serves Excalidraw with
server-side storage, collections and live collaboration. It is public at
`https://excalidraw.harville.dev`, behind Authentik. There is no internal route.

## Layout

One pod holds the ExcaliDash backend and frontend. The frontend proxies `/api`
to the backend over the pod's loopback address. Drawings live in SQLite on the
`excalidraw-data` PVC.

## Data and replication

The PVC uses `longhorn-retain` with the default three replicas, so one replica
sits on each of three nodes and any single node can fail without data loss. SQLite
allows only one writer, so the Deployment runs one pod with a `Recreate`
strategy. A node failure means a short outage while the pod reschedules, not data
loss.

The backend writes a SQLite backup daily at 04:00 UTC and keeps 14. They sit on
the same volume, so they protect against a bad edit or deletion, not against
losing the volume. Longhorn's seven daily snapshots cover the same ground. See
[Storage](../operations/storage.md) for the lack of an off-cluster backup target.

## Access

Authentik guards the site twice:

1. The Ingress uses the `authentik-forwardauth` middleware, so a visitor without
   an Authentik session never reaches ExcaliDash. The `Excalidraw Gate`
   application holds that proxy provider and is hidden from the Authentik
   library.
2. ExcaliDash runs with `AUTH_MODE=oidc_enforced` and signs users in through the
   `Excalidraw` OAuth2 application. There are no local passwords, and drawings
   belong to the Authentik account.

Both applications admit the `Excalidraw Users` group and `authentik Admins`. To
give someone access, add them to `Excalidraw Users` in Authentik. Share and
collaboration links work only for people with that access.

The OAuth2 client secret lives in `excalidraw-oidc` in
`clusters/homelab/apps/secrets/`. Reflector copies it to `authentik`, where the
blueprint reads it, and to `excalidraw`, where the backend reads it.

## First use

Open the site and sign in with Authentik. ExcaliDash creates the account on
first sign-in, and the first account becomes the admin. The backend generates
and keeps its JWT and CSRF secrets on the volume.
