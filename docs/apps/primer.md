# Primer

[Primer](https://github.com/isaiah-harville/Primer) is a self-hosted, multi-user
assistant over your own documents. It is published as an OCI Helm chart, and
this repository deploys it at `https://primer.harville.dev`. It replaced Open
WebUI.

The chart ships no database, no broker, and no model server, so most of what is
in `apps/base/primer/` exists to supply those:

| Piece | Where it comes from |
| --- | --- |
| PostgreSQL + pgvector | `postgres.yaml` — CNPG cluster, pgvector as an ImageVolume extension |
| RabbitMQ | `rabbitmq.yaml` — `RabbitmqCluster`, three nodes for quorum queues |
| Embeddings | `embeddings.yaml` — Text Embeddings Inference on CPU, `bge-small-en-v1.5` |
| Chat model | `vllm-router` in `apps/base/vllm-router` |
| Source objects | SeaweedFS bucket `primer-sources` |
| Identity | Authentik OIDC, via the chart's own `oauth2-proxy` |

## The header boundary

Primer performs no token validation. `oauth2-proxy` verifies the session and
injects `X-Auth-Request-*` headers, which Primer trusts absolutely. Everything
therefore rests on inbound requests never being able to carry those headers
themselves.

The chart expresses that as nginx annotations, which **Traefik ignores
silently**. `middleware.yaml` re-expresses it as a Traefik `Middleware` that
clears each header, and `public.ingress.yaml` attaches it. If either is removed,
anyone who can reach the ingress can be any user they name, and nothing about
the deployment will look broken.

Every Primer service is `ClusterIP`, and the only ingress path is the proxy.

## Manual steps before first reconcile

**Authentik group membership.** The blueprint creates a **Primer Users**
group; add the intended people to it. Authentik admins retain access.

## The source store

Primer's source objects live in the SeaweedFS bucket `primer-sources`, reached
with an identity of its own. Both halves are in this repository:
`seaweedfs-s3-config` carries a `primer` identity scoped to
Read/Write/List/Tagging on that bucket, and `primer-s3.yaml` carries the
matching credentials.

The chart mounts `primer-s3` whole into Control and the two ingestion workers
— the only services that open a source object — so every key in it becomes an
environment variable there. That is why the endpoint and region live in the
secret rather than in the `HelmRelease`. SeaweedFS is not AWS, and
`FSSPEC_S3_ENDPOINT_URL` is how fsspec is told where the bucket is.

Rotating the credential means editing both files together:

```bash
sops clusters/homelab/apps/secrets/seaweedfs-s3-config.yaml
sops clusters/homelab/apps/secrets/primer-s3.yaml
```

SeaweedFS creates the bucket on first write.

## Credentials this repository does manage

`primer-rabbitmq` and `primer-oidc` are SOPS-encrypted in
`clusters/homelab/apps/secrets/`. Both were generated at random on first
commit and can be rotated by re-encrypting them.

`primer-rabbitmq` is read from two directions: the RabbitMQ Cluster Operator
takes its default user from it, and Primer reads `broker-url` from the same
file. Change the password in one place and both follow.

The Postgres URL is not managed here at all — CNPG generates
`primer-postgres-app` with a ready-made `uri` key, and the chart reads that.

## Chart version

The chart is pre-1.0 and published from this repository's own release tags, so
the `HelmRelease` tracks all of `0.x` rather than a single minor. A chart that
fails to install is rolled back by the release's own remediation, which is a
better failure than the deployment quietly sitting on a stale version because
the next tag happened to bump the minor.

## Embedding dimensions

`bge-small-en-v1.5` is 384-dimensional, and the `HelmRelease` pins
`inference.embeddings.dimensions: 384` to match. Changing the model without
changing this number, or changing the number at all, invalidates every stored
vector and requires a full reindex.
