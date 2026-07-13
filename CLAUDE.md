# CLAUDE.md

Operational knowledge for working in this repo. Read this before making changes.

## What this is

GitOps repo for a **k3s HA cluster** (the "homelab" cluster). **Flux** reconciles
everything from `clusters/homelab/`. Nothing is applied by hand — you change YAML,
commit, and Flux converges the cluster. Don't `kubectl apply` to make a change
stick; edit the repo.

## Layout

```
clusters/homelab/   Flux composition (Kustomizations, cluster-specific secrets, patches)
infrastructure/base/ Cluster plumbing: traefik, cert-manager, metallb, longhorn, monitoring, reflector, sources
apps/base/          Reusable app building blocks (HelmRelease + ingress + kustomization)
apps/releases/      Apps deployed from their own GitRepository sources
ansible/            Provisions Ubuntu 24 machines as k3s nodes
docs/, NOTES.md     Runbooks + ops cheatsheet
```

## Flux reconcile order

`clusters/homelab/flux-system/*.kustomization.yaml` define the Flux Kustomizations
and their `dependsOn` chain:

```
sources → infra ─┬→ issuers → certificates → apps
                 ├→ metallb-config
                 └───────────────────────────↗
```

(`apps` waits on `certificates`, `infra`, and `sources`.) The `infra` and `apps`
Kustomizations set `decryption.provider: sops` (secretRef `sops-age`) — the others
carry no encrypted resources. `infra` has `healthChecks` on the core HelmReleases;
`issuers`/`certificates` use `healthCheckExprs` on the cert-manager CRs.

## Adding an app (the common task)

1. Create `apps/base/<name>/` with:
   - `helmrelease.yaml` — `HelmRelease` in namespace `apps`, with the standard
     `install`/`upgrade` remediation block (copy from `apps/base/openwebui/helmrelease.yaml`).
   - `kustomization.yaml` — `namespace: apps`, lists the resources.
   - `ingress.yaml` (optional) — standalone Ingress (see conventions below).
2. If the chart is from a new Helm repo, add a `HelmRepository` under
   `infrastructure/base/sources/` and register it in that dir's `kustomization.yaml`.
3. Register the app dir (and any secret files) in `clusters/homelab/apps/kustomization.yaml`.

## Ingress conventions

- **Internal** services: `ingressClassName: traefik-internal`, host `*.int.harville.dev`.
  Reaches the LAN via the traefik-internal LoadBalancer at **10.1.10.251**.
- **Public** services: `ingressClassName: traefik-public`, host `*.harville.dev`.
  LoadBalancer at **10.1.10.252**.
- The `apps` Kustomization (`clusters/homelab/apps/kustomization.yaml`) auto-patches
  every repo-defined Ingress in namespace `apps` with:
  - `traefik.ingress.kubernetes.io/router.entrypoints: websecure`
  - `tls[0].secretName: harville-wildcard-shared-tls`
  > **Important:** these patches only touch Ingress manifests *in the repo*. They do
  > **not** affect Ingresses rendered by a HelmRelease at runtime (e.g. Harbor) — for
  > those, set ingress class / TLS secret / entrypoint annotation **in the chart values**.
- **Authelia SSO** on an internal app: annotation
  `traefik.ingress.kubernetes.io/router.middlewares: apps-authelia-forwardauth@kubernetescrd`.
  Don't put forwardauth in front of services that authenticate themselves via API
  (S3 access keys, `docker login`) — clients can't traverse it.
- **Homepage** dashboard discovery: `gethomepage.dev/*` annotations on the Ingress.

## TLS / certificates

- One wildcard `Certificate` `harville-wildcard` (`infrastructure/base/certificates/`)
  via cert-manager + the `letsencrypt-dns` ClusterIssuer (Cloudflare DNS-01).
  Covers `*.harville.dev`, `*.int.harville.dev`, `*.harville.ai`, `*.int.harville.ai`,
  `innerswings.com`, `*.innerswings.com`.
- Secret `harville-wildcard-shared-tls` is **reflected** (emberstack reflector) into the
  namespaces listed in the Certificate's `reflector.*` annotations (currently
  `apps,monitoring,longhorn-system`). **If you add an app in a new namespace, add that
  namespace to those annotations** or the cert won't be there.

## Storage (Longhorn)

- Longhorn is the **default StorageClass** (`longhorn`); `local-path` is pinned
  non-default. Just omit `storageClassName` to get Longhorn, or name it explicitly.
- `defaultReplicaCount: 3` + strict anti-affinity → one replica per node, any single
  node can fail with no data loss. Disks auto-create on each node at `/data/longhorn`
  (30% reserved). Provision a node with ansible and its storage appears.
- Consequence: data on Longhorn is ~3x amplified. For an app that does its **own**
  replication (e.g. SeaweedFS), run it **single-replica** and let Longhorn provide
  redundancy — don't stack app-level replication on top of Longhorn-level replication.

## Secrets (SOPS + age)

- Encrypted with **SOPS/age**; recipient public key is in `.sops.yaml`. The creation
  rule matches files under `secrets/` or `sops/` dirs and encrypts `^(data|stringData)$`.
- To add a secret: write the plaintext `Secret` manifest under
  `clusters/homelab/.../secrets/`, then `sops --encrypt --in-place <file>` (run from repo
  root so `.sops.yaml` is picked up). The age **private** key lives only in-cluster
  (`sops-age` secret) — you can encrypt locally but not decrypt without it.
- yamllint/pre-commit excludes `secrets/` and `sops/` dirs.

## Networking (MetalLB)

- Pool `lab-lb-pool` = **10.1.10.251–10.1.10.252** (only 2 IPs, both consumed by
  traefik-internal/.251 and traefik-public/.252). Need a new LoadBalancer IP? Expand
  the pool in `infrastructure/base/metallb-config/ipaddresspool.yaml`. Prefer routing
  through an existing Traefik ingress instead of claiming a new LB IP.

## Services worth knowing

- **traefik** — two instances: `traefik-internal` (LAN) and `traefik-public`.
- **cert-manager** + **letsencrypt-dns** ClusterIssuer (Cloudflare DNS-01).
- **reflector** (emberstack) — copies the wildcard TLS secret across namespaces.
- **longhorn** — distributed block storage / default SC.
- **authelia** — SSO / forwardauth provider.
- **homepage** — dashboard, auto-populated from `gethomepage.dev/*` ingress annotations.
- **kube-prometheus-stack** — monitoring (Grafana/Prometheus/Alertmanager).
- **seaweedfs** — S3 object storage, `s3.int.harville.dev`, buckets `general`/`backups`.
- **harbor** — container registry, public at `harbor.harville.dev`.
- **vllm** — GPU inference, OpenAI-compatible API at `vllm.int.harville.dev` (API-key
  auth), wired into Open WebUI. Two backends behind a router (`apps/base/vllm-router`,
  the vLLM Production Stack router): `apps/base/vllm-wsl` (Qwen3-8B-AWQ, WSL box) and
  `apps/base/vllm-dgx` (Qwen3.6-35B-A3B-FP8, DGX Spark). The router picks the backend by the
  requested model name, so both show up as separate models in Open WebUI.
- **nvidia-device-plugin** (kube-system) — advertises `nvidia.com/gpu`; runs on
  `gpu=true` nodes under the k3s-auto-created `nvidia` RuntimeClass.

## GPU nodes

The `k3s_node` role has two composable per-host flags (inventory):
- **`node_gpu: true`** → generic GPU setup (`gpu.yml`): NVIDIA Container Toolkit
  (k3s then auto-creates the `nvidia` RuntimeClass), `gpu=true` +
  `nvidia.com/gpu.present` labels, and the `dedicated=gpu:NoSchedule` taint. Same
  on bare-metal GPU nodes.
- **`node_wsl: true`** → WSL2-only quirks (`wsl.yml`): the `/`-rshared mount fix
  (GPU device injection needs mount propagation) and a pinned `node-ip`.

GPU workloads set `runtimeClassName: nvidia`, `nodeSelector: {gpu: "true"}`, tolerate
`dedicated=gpu`, and request `nvidia.com/gpu: 1`. The node is **reserved** by the taint:
general workloads (and Longhorn/metallb, which don't tolerate it) stay off, so it never
becomes a storage node; only vLLM + the device plugin run there. node-exporter tolerates
all `NoSchedule` taints so it stays.

There are two GPU nodes, both `gpu=true` (a `nodeName` pin disambiguates their vLLM
deployments — see `apps/base/vllm-dgx/deployment.yaml`):

- **`harvi-desktop`** (`10.1.1.20`, routed subnet) — a WSL2 box, both `node_gpu` and
  `node_wsl`. **WSL caveat:** flannel's VXLAN overlay can't receive inbound on WSL
  mirrored networking, so the node does **no cross-node pod networking** — its vLLM
  (`apps/base/vllm-wsl`) therefore runs with `hostNetwork: true` + `dnsPolicy: Default`
  (binds the node's LAN IP, uses node DNS/egress). The router
  (`apps/base/vllm-router`) reaches it directly at `10.1.1.20:8000` — same as
  SSH/ansible already do — no tunnel needed. See the inventory comment for WSL
  prereqs (systemd, mirrored networking + `firewall=false`, Windows driver, sshd).
- **`spark-a97a`** (DGX Spark, `10.1.10.75`, main cluster subnet) — a normal Linux box (stock DGX
  OS, arm64 GB10 Grace Blackwell), only `node_gpu`. Ordinary pod networking, no
  workarounds; its vLLM (`apps/base/vllm-dgx`) is reached via a normal ClusterIP
  Service.

**Free / reclaim the WSL box's GPU** (it's the intermittent one; its vLLM deployment
is the only consumer — the DGX Spark is a dedicated cluster member, not something to
free/reclaim):

```bash
scripts/gpu.sh free     # scale vllm-wsl to 0, release the GPU
scripts/gpu.sh claim    # scale vllm-wsl to 1, reclaim it
scripts/gpu.sh status
```

## Ops cheatsheet

```bash
# Reconcile from git
flux reconcile source git flux-system -n flux-system
flux reconcile kustomization flux-system -n flux-system --with-source

# Status
flux get kustomizations -A
kubectl -n flux-system describe kustomization infra

# Unstick a wedged kustomization
kubectl -n flux-system rollout restart deployment/kustomize-controller
```
