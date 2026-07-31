# Authentication operations

## Headlamp access

Headlamp is exposed only by the internal Traefik instance. It deliberately has
no ForwardAuth middleware so an Authelia outage does not prevent the Headlamp
login page from loading.

Normal access uses Headlamp's native OIDC flow with Authelia. Kubernetes trusts
the `headlamp` audience and maps Authelia groups with an `oidc:` prefix; only the
`oidc:admins` group is bound to `cluster-admin`.

If Authelia is unavailable, mint a short-lived break-glass token from an
existing administrative kubeconfig and paste it into Headlamp:

```bash
kubectl create token headlamp-break-glass -n apps --duration=15m
```

The break-glass ServiceAccount does not automount its token and no long-lived
token Secret is stored. Do not enable Headlamp's
`unsafeUseServiceAccountToken`: that would silently give every client able to
reach the internal URL shared cluster-admin access.

## Authelia availability

Authelia currently uses SQLite, so it runs as a single-writer StatefulSet. Its
2 GiB PVC is a healthy three-replica Longhorn volume and receives the default
daily Longhorn snapshots. Startup, readiness, and liveness probes provide fast
failure detection; a critical priority class and explicit resource requests
make rescheduling more reliable.

A PodDisruptionBudget is intentionally omitted. With one replica and a
ReadWriteOnce volume, `minAvailable: 1` would block voluntary node drains rather
than create availability. True active-active Authelia requires a deliberate
migration from SQLite to an external highly available PostgreSQL or MySQL
database, followed by at least two Authelia replicas. Longhorn snapshots are
local recovery points, not a substitute for the off-cluster backup target
described in the backup runbook.
