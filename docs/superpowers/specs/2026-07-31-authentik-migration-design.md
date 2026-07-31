# Authentik Migration Design

## Goal

Replace Authelia with a highly available, GitOps-managed Authentik deployment
without creating another Kubernetes cluster. Preserve the existing protected
application behavior and make Headlamp's native OIDC login work against
Authentik. Existing Authelia users, passwords, sessions, and MFA credentials do
not need to migrate.

## Scope

The migration includes:

- Authentik server, worker, ingress, secrets, monitoring, and PostgreSQL
  resources in the existing `apps` namespace.
- Git-managed Authentik blueprints for the six ForwardAuth applications and
  Headlamp OIDC.
- Traefik middleware and callback routing for all protected applications.
- Kubernetes API-server OIDC and Headlamp OIDC configuration.
- Grafana auth-proxy header mapping.
- Removal of Authelia resources, secrets, chart source, configuration, and
  documentation.

The migration excludes Omni and Dex. Their configuration and runtime behavior
remain unchanged.

## Constraints and Decisions

- Perform a single Flux reconciliation replacement, not a staged parallel
  migration.
- Keep the identity-provider URL `https://auth.harville.dev`.
- Bootstrap Authentik's built-in `akadmin` user with email
  `admin@int.harville.dev` entirely from Git-managed configuration.
- Store only a Django password hash, bootstrap API token, Authentik secret key,
  PostgreSQL credentials, and OAuth client secrets in SOPS-encrypted Secrets.
- Manage applications, providers, outpost assignments, and claim mappings with
  version-controlled Authentik blueprints.
- Use the UI for later user creation, user enrollment, optional MFA enrollment,
  and policy refinements. MFA is not mandatory.
- Initially allow every authenticated user to access the six proxy-protected
  applications.
- Do not depend on the `dl380` worker being available. It is frequently down.
- Do not add Redis. Authentik 2025.10 and newer stores cache, sessions, and task
  coordination in PostgreSQL.

## Architecture

### Authentik

Install the official Authentik Helm chart with a patch-only semver range within
the selected stable release line. Run two server replicas and two worker
replicas. Both component types are stateless; all durable state and coordination
live in PostgreSQL.

Configure:

- readiness and liveness probes;
- `system-cluster-critical` priority;
- explicit CPU and memory requests;
- required hostname pod anti-affinity between replicas of the same component;
- topology spreading across available Kubernetes nodes;
- a PodDisruptionBudget retaining at least one server and one worker;
- Prometheus metrics and ServiceMonitors for both server and worker;
- an Ingress at `auth.harville.dev` through `traefik-public` with the reflected
  wildcard TLS Secret.

Scheduling must not select a particular worker role or hostname. Control-plane
nodes are valid workload targets in this cluster, so the two server replicas,
two worker replicas, and three PostgreSQL instances can remain distributed when
`dl380` is absent.

The embedded proxy outpost runs with each server replica. Because its state is
PostgreSQL-backed, the Authentik server Service can load-balance ForwardAuth
requests across both replicas.

### PostgreSQL

Use CloudNativePG, which is already installed in the existing Kubernetes
cluster. A CloudNativePG `Cluster` is a PostgreSQL database cluster, not another
Kubernetes cluster.

Replace the Authelia-specific database resources with an
`authentik-postgres` database cluster configured with:

- three PostgreSQL instances;
- quorum synchronous replication using `ANY 1`;
- required hostname anti-affinity;
- unsupervised primary updates;
- 5 GiB `longhorn-database` storage per instance;
- retained Longhorn volumes and the default snapshot job;
- resource requests, critical priority, PodMonitor, and operator-managed
  disruption protection.

Authentik connects to the read/write service over the cluster network. The
database owner and credentials come from a SOPS-encrypted
`kubernetes.io/basic-auth` Secret. No PostgreSQL read replica is exposed to
Authentik initially; the deployment is too small to justify split read traffic.

## Declarative Identity Configuration

Mount one Git-managed blueprint bundle into the Authentik worker pods. The
bundle is automatically discovered and reconciled. Keep dependent objects in a
single blueprint, ordered with blueprint IDs and `!KeyOf`/`!Find` references so
file discovery order cannot break dependencies. Blueprint application is atomic:
any invalid entry rolls back the whole bundle.

Resolve OAuth client secrets with Authentik's `!Env` blueprint tag. The worker
receives those values through `envFrom` from the SOPS Secret. Secrets never
appear in the blueprint ConfigMap.

The blueprint defines:

- one application and single-application proxy provider for each of:
  - Open WebUI at `https://webui.harville.dev`;
  - SeaweedFS Admin at `https://seaweedfs.int.harville.dev`;
  - OpenVitae admin/API at `https://isaiah.harville.dev`;
  - Flux UI at `https://flux.int.harville.dev`;
  - Longhorn UI at `https://longhorn.int.harville.dev`;
  - Grafana at `https://grafana.int.harville.dev`;
- assignment of all six proxy applications to the embedded outpost;
- one public OAuth2/OIDC provider and application for Headlamp;
- an explicit `groups` scope/property mapping suitable for Kubernetes RBAC;
- use of Authentik's default authentication and authorization flows.

The initial proxy applications have no restrictive policy binding beyond a
valid authenticated session. Later UI changes can add users, groups, MFA, and
access policies. Blueprint entries state only fields Git must own so unrelated
UI-managed fields are not overwritten on reconciliation.

## ForwardAuth and Application Integration

Replace `authelia-forwardauth` with an `authentik-forwardauth` Traefik
Middleware. It sends checks to the in-cluster Authentik embedded-outpost endpoint
and forwards the supported `X-authentik-*` identity and metadata headers.

Each protected hostname must route `/outpost.goauthentik.io/` to the Authentik
server Service without applying ForwardAuth to that callback path. Dedicated
Ingress resources provide these routes where the application chart cannot.
Traefik's longest-prefix path matching keeps application traffic on its existing
backend.

Update all six existing middleware references. Preserve OpenVitae's existing
partial protection: only `/admin` and `/api` remain protected; its public CV and
S3 routes remain anonymous. The SeaweedFS S3 API remains unprotected by
ForwardAuth so S3 clients continue using access keys.

Grafana continues using auth-proxy mode but changes its identity header from
Authelia's `Remote-Email` to Authentik's `X-authentik-email`. It keeps automatic
user creation, disabled form login, and the current default organization role.

## Headlamp and Kubernetes OIDC

Headlamp remains reachable through its internal Ingress without ForwardAuth, so
the login page and break-glass token path do not depend on the proxy outpost.

Create a dedicated public Authentik OAuth2/OIDC provider with:

- client ID `headlamp`;
- PKCE enabled;
- no client secret requirement;
- redirect URI `https://headlamp.int.harville.dev/oidc-callback`;
- scopes `openid`, `profile`, `email`, and `groups`;
- issuer `https://auth.harville.dev/application/o/headlamp/`.

Configure Headlamp and the Kubernetes API server with that exact issuer and
audience. Kubernetes continues prefixing groups with `oidc:`. Bind Authentik's
administrator group claim to `cluster-admin`, and keep the existing short-lived
`headlamp-break-glass` ServiceAccount flow unchanged.

Acceptance requires completing the browser redirect, receiving a token with the
`headlamp` audience and `groups` claim, and successfully calling the Kubernetes
API through Headlamp. Merely loading the Headlamp login page is not sufficient.

## Secrets and Bootstrap

Create SOPS-encrypted Authentik Secrets containing:

- `AUTHENTIK_SECRET_KEY`;
- `AUTHENTIK_BOOTSTRAP_PASSWORD_HASH`;
- `AUTHENTIK_BOOTSTRAP_TOKEN`;
- `AUTHENTIK_BOOTSTRAP_EMAIL=admin@int.harville.dev`;
- PostgreSQL username and password;
- any blueprint-consumed OAuth client secrets.

Use a current Django PBKDF2 password hash, never a plaintext bootstrap password.
Bootstrap settings are consumed only on the first database initialization. Add
SOPS-MAC-to-pod-annotation replacements for startup-only Authentik secrets so a
Git-managed secret change rolls server and worker pods when required.

## Cutover and Failure Behavior

Flux applies the new Authentik resources and changed consumers in one
reconciliation and prunes the removed Authelia objects. Kubernetes apply order
must not be treated as a runtime readiness dependency. During the interval before
Authentik, its database, and its blueprints are ready, protected routes can
temporarily return authentication errors. This downtime is an accepted
consequence of selecting the single-reconciliation approach.

Readiness probes keep unready Authentik server replicas out of the Service.
Multiple server and worker replicas tolerate one pod or node failure. Three
PostgreSQL instances with `ANY 1` synchronous replication tolerate one database
pod or node failure while preserving acknowledged writes. Required hostname
anti-affinity prevents the frequently absent `dl380` from becoming a single
point of failure and prevents redundant replicas from sharing a node.

A blueprint failure leaves its entire managed object set unapplied. Authentik
and blueprint status must therefore be checked before treating the migration as
successful. Headlamp's break-glass token remains the recovery route for cluster
administration if OIDC is unavailable.

Authelia's users, credentials, MFA records, sessions, SQLite PVC, and PostgreSQL
database are intentionally not migrated. Flux pruning removes their Kubernetes
objects. Retained CloudNativePG/Longhorn volumes may require a later explicit
storage cleanup; no destructive live storage command is part of this repository
change.

## Validation

Before committing implementation changes:

1. Render the Authentik chart with the repository values and supported CRD API
   versions.
2. Run `kubectl kustomize` for apps, infra, and flux-system.
3. Validate normal YAML and parse/render the Authentik blueprint with tooling
   that understands Authentik custom YAML tags.
4. Run `terraform -chdir=terraform/omni fmt -check -recursive`.
5. Run `uvx pre-commit run --all-files`.

After Flux reconciliation, verify:

1. Two Authentik servers and two workers are Ready on distinct available nodes.
2. The CloudNativePG cluster reports three instances and a healthy synchronous
   primary/standby topology while `dl380` is absent.
3. The custom blueprint reports a successful application.
4. `https://auth.harville.dev` serves Authentik and
   `/outpost.goauthentik.io/ping` returns HTTP 204 on every protected hostname.
5. Every proxy-protected route redirects an anonymous browser to Authentik and
   returns to the original URL after login.
6. SeaweedFS S3 API access, OpenVitae public routes, and other API-key clients
   remain outside ForwardAuth.
7. Grafana receives the Authentik email identity and creates/logs in the user.
8. Headlamp completes OIDC and the Authentik administrator can access the
   Kubernetes API with the expected RBAC group.
9. The short-lived Headlamp break-glass token still works.

## Documentation

Update `AGENTS.md`, the root README, Talos documentation, authentication
operations, monitoring operations, Flux timeout comments, and relevant manifest
comments. Document Authentik bootstrap, HA layout, blueprint ownership, optional
MFA, Headlamp issuer/RBAC, recovery checks, and the fact that Omni/Dex is
unchanged.

## References

- [Authentik Kubernetes installation](https://docs.goauthentik.io/install-config/install/kubernetes)
- [Authentik high availability](https://docs.goauthentik.io/install-config/high-availability/)
- [Authentik automated installation](https://docs.goauthentik.io/install-config/automated-install)
- [Authentik blueprints](https://docs.goauthentik.io/customize/blueprints)
- [Authentik blueprint YAML tags](https://docs.goauthentik.io/customize/blueprints/v1/tags)
- [Authentik forward auth](https://docs.goauthentik.io/add-secure-apps/providers/proxy/forward_auth)
- [Authentik Traefik integration](https://docs.goauthentik.io/add-secure-apps/providers/proxy/server_traefik/)
- [Authentik 2025.10 Redis removal](https://docs.goauthentik.io/releases/2025.10)
