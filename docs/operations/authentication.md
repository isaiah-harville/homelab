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

Authelia stores durable application state in a three-instance CloudNativePG
cluster. PostgreSQL uses quorum synchronous replication (`ANY 1`) and required
hostname anti-affinity, so an acknowledged write exists on the primary and at
least one standby and the instances are spread across nodes. CloudNativePG's
operator-managed disruption budgets protect the primary and replica quorum
during voluntary disruption.

Each instance has a retained 5 GiB Longhorn volume using the
`longhorn-database` StorageClass. That class deliberately uses one block replica:
PostgreSQL already maintains three independent copies, so Longhorn replication
would otherwise amplify them to nine. The PVCs inherit Longhorn's default daily
snapshot job. Those snapshots are local recovery points, not off-cluster disaster
recovery backups.

On first rollout, an idempotent init container creates the PostgreSQL schema and
uses Authelia's supported storage commands to copy stable user identifiers, TOTP
configurations, and WebAuthn credentials from the old SQLite database. The old
PVC and a marker file make retries safe; remove the migration container only
after the PostgreSQL-backed deployment has been verified.

Authelia remains one replica for now. Its in-memory session provider and
filesystem notifier are not safe for active-active operation. Scale it only
after moving sessions to a supported Redis Sentinel deployment and notifications
to a network provider; simply increasing `replicas` would cause intermittent
logouts and inconsistent reset notifications. The existing single pod keeps its
critical priority, resource request, and health probes for reliable rescheduling.
