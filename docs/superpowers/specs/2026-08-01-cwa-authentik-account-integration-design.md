# CWA Authentik Account Integration Design

## Goal

Allow members of the Authentik `Books Users` group to open
`https://calibre.int.harville.dev` and receive an automatically provisioned,
non-administrative Calibre-Web-Automated (CWA) account. Users can browse and
download the shared library without maintaining a second password.

This change does not modify Shelfmark metadata providers and does not store or
use the previously supplied Hardcover token.

## Root Cause

The live Authentik application for CWA has one policy binding, restricted to
`authentik Admins`. Anna's Shelfmark OIDC login succeeds and creates a normal
Shelfmark account, but membership in `Books Users` does not authorize the CWA
ForwardAuth application.

The live CWA database also shows reverse-proxy authentication and automatic
account creation disabled. CWA currently contains only its bootstrap admin and
guest users. Allowing the group through Authentik without changing CWA would
therefore expose CWA's separate login page without creating a usable account.

Shelfmark's setup wizard is global administration, not per-user onboarding.
Anna is correctly provisioned as a normal Shelfmark user and is not expected to
launch that wizard.

## Authorization and Identity Flow

The Authentik blueprint will add `Books Users` to the CWA application's policy
bindings while retaining `authentik Admins`. Traefik continues to protect the
internal CWA Ingress with the existing Authentik ForwardAuth middleware.

After Authentik authorizes the request, the middleware passes the trusted
`X-authentik-username` response header to CWA. CWA uses that value as its local
username. On first access, CWA creates a user with its configured default role;
subsequent requests map the same case-insensitive username to that account.

Only the Authentik-protected internal Ingress exposes CWA outside the cluster.
The trusted header must not be accepted from an untrusted public route.

## Declarative CWA Configuration

CWA stores authentication settings in `/config/app.db` and does not expose
equivalent container environment variables. The Books Deployment will mount a
small ConfigMap-backed bootstrap script and run it as the CWA container's
`postStart` hook.

The script waits until CWA has created and migrated the `settings` table, then
performs one idempotent SQLite transaction that:

- enables reverse-proxy header authentication;
- sets the login header to `X-authentik-username`;
- enables automatic reverse-proxy user creation; and
- adds the CWA download permission to the default role while preserving any
  existing default-role permissions.

The hook supports both the existing retained database and a new empty PVC. It
fails the container startup if the settings schema never becomes available,
rather than silently running without SSO.

New Books users receive browse and download access but no upload, edit, delete,
or administrator permissions. CWA account authorization remains independent of
Shelfmark's admin role.

## Administration and Recovery

CWA's native bootstrap administrator remains unchanged. Because requests
arriving through ForwardAuth contain an Authentik username, native
administration is performed through a direct temporary port-forward, which does
not add the trusted proxy header:

```bash
kubectl -n apps port-forward service/calibre-web-automated 8083:8083
```

An administrator then opens `http://localhost:8083` and uses the native CWA
administrator account. This also provides a recovery path if Authentik is
unavailable. The native administrator password must be changed from its
bootstrap value.

Removing a user from `Books Users` immediately prevents new CWA requests at
Authentik. The local CWA account remains stored for history and preferences but
cannot be reached through the protected route unless access is restored.

## Testing and Acceptance

Repository validation will assert that:

- the CWA Authentik application permits both `Books Users` and
  `authentik Admins`;
- the CWA Ingress still uses internal Traefik and Authentik ForwardAuth;
- the Deployment mounts and executes the bootstrap script;
- the script selects `X-authentik-username`, enables auto-creation, and grants
  only the download bit in addition to existing defaults; and
- all cluster Kustomizations and pre-commit checks pass.

After Flux applies the commit, live acceptance is:

1. The Books Deployment is Ready and the bootstrap hook completes.
2. The CWA settings row reports proxy authentication and auto-creation enabled,
   with `X-authentik-username` as its header.
3. Anna opens CWA after authenticating through Authentik and a non-admin local
   CWA account named `anna` is created automatically.
4. Anna can browse and download books but cannot access CWA administration.
5. A user outside `Books Users` is denied by Authentik.
