# Authentication operations

## Headlamp access

Headlamp is exposed only by the internal Traefik instance. It deliberately has
no ForwardAuth middleware so an Authentik outage does not prevent the Headlamp
login page from loading.

Normal access uses Headlamp's native Authorization Code + PKCE flow with
Authentik. Both Headlamp and Kubernetes use issuer
`https://auth.harville.dev/application/o/headlamp/` and audience `headlamp`.
Kubernetes maps the `groups` claim with an `oidc:` prefix; only
`oidc:authentik Admins` is bound to `cluster-admin`.

If Authentik is unavailable, mint a short-lived break-glass token from an
existing administrative kubeconfig and paste it into Headlamp:

```bash
kubectl create token headlamp-break-glass -n apps --duration=15m
```

The break-glass ServiceAccount does not automount its token and no long-lived
token Secret is stored. Do not enable Headlamp's
`unsafeUseServiceAccountToken`: that would silently give every client able to
reach the internal URL shared cluster-admin access.

## Authentik availability

Two stateless Authentik server replicas handle UI, API, OIDC, and the embedded
proxy outpost. Two stateless worker replicas reconcile blueprints and process
background tasks. Sessions, cache, configuration, and task coordination all
live in PostgreSQL; Authentik does not use Redis. Both deployments use hard
hostname anti-affinity, topology spreading, and a disruption budget retaining
one replica.

The `authentik-postgres` CloudNativePG cluster has three instances. PostgreSQL
uses quorum synchronous replication (`ANY 1`) and required hostname
anti-affinity, so an acknowledged write exists on the primary and at least one
standby. Workloads may schedule on control-plane nodes and do not depend on the
frequently unavailable `dl380` worker.

Each instance has a retained 5 GiB Longhorn volume using the
`longhorn-database` StorageClass. That class deliberately uses one block replica:
PostgreSQL already maintains three independent copies, so Longhorn replication
would otherwise amplify them to nine. The PVCs inherit Longhorn's default daily
snapshot job. Those snapshots are local recovery points, not off-cluster disaster
recovery backups.

## Bootstrap and configuration ownership

The `authentik-core` SOPS Secret bootstraps the built-in `akadmin` account with a
Django password hash, an API token, and `admin@int.harville.dev`. Bootstrap
values are consumed only when the database is first initialized. The mounted
`Homelab` blueprint owns six proxy applications/providers, the Headlamp OIDC
provider, its groups claim, and embedded-outpost assignments. Users and optional
MFA factors are enrolled later through the UI.

## Recovery checks

```bash
kubectl -n apps get pods -l app.kubernetes.io/instance=authentik -o wide
kubectl -n apps get cluster.postgresql.cnpg.io authentik-postgres
curl -fsS -o /dev/null -w '%{http_code}\n' \
  https://webui.harville.dev/outpost.goauthentik.io/ping
curl -fsS https://auth.harville.dev/application/o/headlamp/.well-known/openid-configuration \
  | jq -e '.issuer == "https://auth.harville.dev/application/o/headlamp/"'
```

Expect two Ready server pods, two Ready worker pods, three healthy PostgreSQL
instances, HTTP 204 from the outpost ping, and the exact Headlamp issuer. Check
the Authentik Admin UI under **Customization → Blueprints** for a successful
`Homelab` application. If OIDC is down, use the 15-minute Headlamp break-glass
token above.
