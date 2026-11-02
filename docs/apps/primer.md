# Primer

[Primer](https://github.com/isaiah-harville/Primer) is a self-hosted, multi-user
assistant over your own documents. It is published as an OCI Helm chart, and
this repository deploys it at `https://primer.harville.dev`. It replaced Open
WebUI.

The chart ships no database, no broker, and no model server, so most of what is
in `apps/primer/primer/app/` exists to supply those:

| Piece | Where it comes from |
| --- | --- |
| PostgreSQL | `postgres.yaml` — CNPG cluster |
| Vectors | The chart's bundled Qdrant, on a 20Gi Longhorn volume |
| RabbitMQ | `rabbitmq.yaml` — `RabbitmqCluster`, three nodes for quorum queues |
| Embeddings | `embeddings.yaml` — Text Embeddings Inference on CPU, `Qwen3-Embedding-0.6B` |
| Reranker | `reranker.yaml` — Text Embeddings Inference on CPU, `bge-reranker-base` |
| Chat models | `apps/inference/llama-cpp/app/<model>`, one llama.cpp deployment each, fronted by `vllm-router` |
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
sops apps/seaweedfs/seaweedfs/app/seaweedfs-s3-config.sops.yaml
sops apps/primer/primer/app/primer-s3.sops.yaml
```

SeaweedFS creates the bucket on first write.

## Credentials this repository does manage

`primer-rabbitmq` is SOPS-encrypted in `apps/primer/primer/app/`, and
`primer-oidc` (shared with Authentik) in `clusters/homelab/apps/secrets/`. Both were generated at random on first
commit and can be rotated by re-encrypting them.

`primer-rabbitmq` is read from two directions: the RabbitMQ Cluster Operator
takes its default user from it, and Primer reads `broker-url` from the same
file. Change the password in one place and both follow.

The Postgres URL is not managed here at all — CNPG generates
`primer-postgres-app` with a ready-made `uri` key, and the chart reads that.

## Chart version

The chart is published from Primer's own release tags, and the `HelmRelease`
tracks all of `1.x` rather than a single minor. A chart that fails to install
is rolled back by the release's own remediation, which is a better failure
than the deployment quietly sitting on a stale version because the next tag
happened to bump the minor. A new major is a deliberate edit to the range,
after reading Primer's upgrade notes.

The chart ships its own embedding and reranking servers. Both are turned off
here (`bundled.enabled: false`) in favour of `embeddings.yaml` and
`reranker.yaml`, which pin the ONNX exports that run at usable speed on these
CPUs.

### Moving from 0.x to 1.0

Primer 1.0 stores vectors in Qdrant only, so the libraries are empty to search
until they are rebuilt. After the release is upgraded:

1. Reindex each library: `POST /api/v1/libraries/{id}/documents/reindex`, or
   the reindex action on the library page.
2. Once every library answers again, drop the old vectors from Postgres:
   `DROP SCHEMA vectors CASCADE;`. The CNPG image can keep loading pgvector
   until then; nothing in Primer uses it.

## GPU capacity

There are two GPUs in this cluster and both are 4GB laptop parts: an RTX A2000
Laptop (Ampere, SM86) and a Quadro T1000 (Turing, SM75). The device plugin hands
out whole cards, so **two GPU models is the hard ceiling** — a third GPU deployment
does not run slowly, it sits `Pending` forever.

Both cards are therefore spoken for: Qwen3.5-4B has the A2000 and Ministral
reasoning has the T1000. Qwen3.5-9B runs on CPU on `talos-6t5-q1d`, which has
room for its 8Gi request. It uses one request slot and an 8k context to bound
memory use; responses will be slower than on the GPU models. vLLM remains
scaled to zero.

Another GPU model means taking a card from one of these two. Primer can also
reach hosted or self-hosted providers configured from its settings page.

Two consequences of the hardware are worth knowing before changing a model:

- **SM75/SM86 rule out fp8.** Native FP8 needs SM89 or newer, so vLLM cannot
  use an fp8 KV cache here. llama.cpp's `q8_0` KV cache has no such
  requirement, which lets the GPU deployments hold their context beside their
  weights on 4GB.
- **The quantization has to exist.** vLLM needs a published AWQ or GPTQ.
  Ministral 3 `-2512` shipped GGUF only, and at bf16 its 3.85B parameters need
  roughly 7.7GB — which is why it runs under llama.cpp rather than vLLM.

## Embedding dimensions

`Qwen3-Embedding-0.6B` is 1024-dimensional, and the `HelmRelease` pins
`inference.embeddings.dimensions: 1024` to match.

Changing the model, or the number, is not a config change. Every stored
vector was made by the old model and is the old width, so a model change is:

1. Change `inference.embeddings.model` and `dimensions` together.
2. Reindex every library: `POST /api/v1/libraries/{id}/documents/reindex`.

The model runs on CPU because both GPUs are held by the chat models, and it
is roughly 18x the parameters of the `bge-small-en-v1.5` it replaced — so
ingestion throughput, not search latency, is what pays for the better
retrieval.
