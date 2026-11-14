# Excalidraw

[ExcaliDash](https://github.com/ZimengXiong/ExcaliDash) serves Excalidraw with
server-side storage, collections and live collaboration. It is internal only, at
`https://excalidraw.int.harville.dev`.

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

## First use

Open the site and register. The first account becomes the admin. The backend
generates and keeps its JWT and CSRF secrets on the volume. Sign-in is local;
switching to Authentik means adding OIDC settings and a client secret.
