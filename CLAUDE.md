# CLAUDE.md

Operational knowledge for working in this repo. Read this before making changes.

## What this is

GitOps repo for a **Talos Linux cluster** (the "homelab" cluster) managed by a
**self-hosted Omni**. **Flux** reconciles everything at the k8s layer from
`clusters/homelab/`. Nothing k8s-side is applied by hand — you change YAML,
commit, and Flux converges the cluster. Don't `kubectl apply` to make a change
stick; edit the repo.

The machine/OS layer is **Talos** (immutable, API-driven — no SSH, no config
management). Machines are provisioned and their lifecycle (Talos + k8s upgrades,
node health) is driven from **Omni**, not from this repo's manifests. Talos +
Omni replaced the old k3s + Ansible + kube-vip + kured + medik8s stack entirely.

## Layout

```
omni-server/         Self-hosted Omni (docker-compose + runbook) — the management plane
talos/               Talos image schematic + Omni cluster template + machine-config patches
terraform/omni/      Terraform for the Omni cluster (GitOps for the cluster template)
clusters/homelab/    Flux composition (Kustomizations, cluster-specific secrets, patches)
infrastructure/base/ Cluster plumbing: traefik, cert-manager, metallb, longhorn, monitoring, reflector, sources
apps/base/           Reusable app building blocks (HelmRelease + ingress + kustomization)
apps/releases/       Apps deployed from their OWN external git repos (see below)
```

## Provisioning: Talos + Omni (replaces ansible)

There is **no ansible** and no per-node OS config in this repo. To stand up or
extend the cluster:

1. **Omni** (`omni-server/`) is the management plane. It runs in Docker *outside*
   the cluster (must survive a node wipe), fronts auth via **Dex → authelia**
   (with a static break-glass admin), and terminates the SideroLink WireGuard
   tunnel machines join through. See `omni-server/README.md`.
2. **Talos image** (`talos/image/schematic.yaml`) is an Image Factory schematic
   pinning the system extensions Longhorn needs (`iscsi-tools`, `util-linux-tools`).
3. **Cluster template** (`talos/omni/cluster-template.yaml`) defines the topology
   (3 laptops control-plane/etcd, dl380 + thinkcentre-01 workers) and pins the
   Talos + k8s versions. Machine-config **patches** live in `talos/omni/patches/`:
   - `controlplane-vip.yaml` — floating API VIP **10.1.10.9** (replaces kube-vip).
   - `allow-scheduling.yaml` — run workloads on control-plane nodes (needed for
     Longhorn's 3-replica anti-affinity with only 2 dedicated workers).
   - `install-disk.yaml` / `longhorn-disk.yaml` — OS disk + dedicated Longhorn disk.

   Full bring-up runbook: `talos/README.md`. Node UUIDs and per-node disk
   selectors are filled in at enrollment time.
4. **Upgrades / node health / reboots** are driven from Omni (rolling, one node at
   a time). No `talosctl upgrade` by hand, no kured, no medik8s.

The kubeconfig comes from Omni (`omnictl kubeconfig --cluster homelab`), and Flux
is bootstrapped onto the cluster from this repo.

## Terraform for Omni + self-hosted runner

`terraform/omni/` manages the Omni cluster (cluster, machine sets, node
assignments, config patches) with the `siderolabs/omni` provider — the GitOps
path for what `omnictl cluster template sync` does by hand. It **reads the same
patch files** under `talos/omni/patches/`, so patch content stays single-sourced;
keep `terraform/omni/locals.tf` and `cluster-template.yaml` topologies in step.

Jobs run on an **in-cluster GitHub Actions self-hosted runner** (ARC,
`infrastructure/base/actions-runner-controller/`, namespaces `arc-systems` /
`arc-runners`) so they can reach the **LAN-only** Omni + SeaweedFS. The runner pod
gets `OMNI_*` and `AWS_*` (S3) creds via `envFrom` from two SOPS secrets, so the
workflow needs no GitHub secrets. `.github/workflows/terraform.yaml`: plan on PR,
apply on merge to `main`. **State** lives in SeaweedFS S3 (`tfstate` bucket); Omni
is the real source of truth, so lost state is re-`import`ed, never catastrophic.

The provider is **alpha** and this is **not activated yet** — ARC + its secrets are
commented out in `clusters/homelab/infra/kustomization.yaml`, and the live cluster
must be `terraform import`ed before the first apply. Full runbook + import steps:
`terraform/omni/README.md`. Until it's stable, `cluster-template.yaml` +
`omnictl cluster template sync` remain the working path.

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

## Apps from external repos (`apps/releases/`)

Some apps aren't built from a Helm chart here — they live in their **own GitHub
repos** and this repo only points Flux at them. Each `apps/releases/<name>/` holds:

- `gitrepository.yaml` — a Flux `GitRepository` (in `flux-system`) for the app's repo.
- `release.kustomization.yaml` — a Flux `Kustomization` whose `spec.path` points at a
  deploy dir **inside that external repo** (not this one), `dependsOn` infra +
  certificates. This is why `orion`, `pigeon`, `swing-thoughts`, `openvitae` show up
  as their own top-level entries in `flux get kustomizations -A`.
- `ingress.yaml` — the Ingress lives here (so it gets the `apps` Ingress patches).

They're still registered as resources in `clusters/homelab/apps/kustomization.yaml`,
so the parent `apps` Kustomization creates the GitRepository + child Kustomization,
and the child then reconciles the app from its own source. `apps/base/` HelmRelease
apps and these external-repo apps are mixed together in that one kustomization list.

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
- **Omni is external and can't use this in-cluster cert.** Its host mints its own
  `*.int.harville.dev` cert with **lego (Cloudflare DNS-01)**, same token, independent
  renewal — see `omni-server/README.md`.

## Storage (Longhorn on Talos)

- Longhorn is the **default StorageClass** (`longhorn`); `local-path` is pinned
  non-default. Omit `storageClassName` to get Longhorn, or name it explicitly.
- **Data path is `/var/mnt/longhorn`** (Helm `defaultDataPath`). On Talos that's a
  **dedicated disk** mounted via `UserVolumeConfig` (NOT the deprecated
  `machine.disks`), made visible to Longhorn's pods by a kubelet `extraMounts` bind —
  both in `talos/omni/patches/longhorn-disk.yaml`. Enroll a node with that patch and
  its storage appears. Longhorn also needs the `iscsi-tools` + `util-linux-tools`
  system extensions (baked into the image via `talos/image/schematic.yaml`).
  > **Single-disk nodes:** `UserVolumeConfig` claims a *separate* disk. Single-NVMe
  > laptops have none — carve a partition or fall back to a system-disk directory for
  > that machine class (see the caveat in `longhorn-disk.yaml`).
- `defaultReplicaCount: 3` + strict anti-affinity → one replica per node, any single
  node can fail with no data loss. Disks auto-create per node (30% reserved).
- Consequence: data on Longhorn is ~3x amplified. For an app that does its **own**
  replication (e.g. SeaweedFS), run it **single-replica** and let Longhorn provide
  redundancy — don't stack app-level replication on top of Longhorn-level replication.

## Pod Security (Talos)

Talos enforces Pod Security **baseline** by default (kube-system exempt). Namespaces
that run privileged pods are labeled `pod-security.kubernetes.io/enforce: privileged`
in `infrastructure/base/namespaces/namespaces.yaml`: **longhorn-system** (engine/
manager), **metallb-system** (speaker: hostNetwork + NET_RAW), **monitoring**
(node-exporter: hostNetwork/hostPath). Add the label if you introduce another
privileged workload's namespace, or Talos baseline will block its pods.

## Secrets (SOPS + age)

- Encrypted with **SOPS/age**; recipient public key is in `.sops.yaml`. The creation
  rule matches files under `secrets/` or `sops/` dirs and encrypts `^(data|stringData)$`.
- To add a secret: write the plaintext `Secret` manifest under
  `clusters/homelab/.../secrets/`, then `sops --encrypt --in-place <file>` (run from repo
  root so `.sops.yaml` is picked up). The age **private** key lives only in-cluster
  (`sops-age` secret) — you can encrypt locally but not decrypt without it.
- yamllint/pre-commit excludes `secrets/` and `sops/` dirs.
- **Rollout-on-secret-change:** `clusters/homelab/apps/kustomization.yaml` has a
  `replacements` block that copies each authelia secret's `sops.mac` into a pod
  annotation on the authelia HelmRelease. Because the MAC changes whenever the
  secret content changes, editing an authelia secret changes the annotation, which
  rolls the pods — otherwise a plain Secret update wouldn't restart them. Reuse this
  pattern for any app that reads secrets only at startup.

## Networking (MetalLB)

- Pool `lab-lb-pool` = **10.1.10.251–10.1.10.252** (only 2 IPs, both consumed by
  traefik-internal/.251 and traefik-public/.252). Need a new LoadBalancer IP? Expand
  the pool in `infrastructure/base/metallb-config/ipaddresspool.yaml`. Prefer routing
  through an existing Traefik ingress instead of claiming a new LB IP.
- The control-plane API VIP (**10.1.10.9**) is served by Talos itself (see
  `controlplane-vip.yaml`), not MetalLB.

## Services worth knowing

- **traefik** — two instances: `traefik-internal` (LAN) and `traefik-public`.
- **cert-manager** + **letsencrypt-dns** ClusterIssuer (Cloudflare DNS-01).
- **reflector** (emberstack) — copies the wildcard TLS secret across namespaces.
- **longhorn** — distributed block storage / default SC.
- **authelia** — SSO / forwardauth provider. Also fronts Omni's login (via Dex).
- **homepage** — dashboard, auto-populated from `gethomepage.dev/*` ingress annotations.
- **searxng** — self-hosted metasearch; backs Open WebUI's web-search
  (`http://searxng:8080`, see `apps/base/openwebui`).
- **kube-prometheus-stack** — monitoring (Grafana/Prometheus/Alertmanager).
- **seaweedfs** — S3 object storage, `s3.int.harville.dev`, buckets `general`/`backups`.
- **harbor** — container registry, public at `harbor.harville.dev`.
- **vllm** — OpenAI-compatible inference at `vllm.int.harville.dev` (API-key auth),
  wired into Open WebUI. See "GPU / vLLM" below.

## GPU / vLLM (external, not a cluster node)

There are **no GPU nodes in the cluster** — the Talos cluster is CPU-only. GPU
inference runs on a **standalone WSL box** (`harvi-desktop`, `10.1.10.20`) that is
**not** a Talos node. vLLM runs on that box directly and serves an OpenAI-compatible
API on `10.1.10.20:8000`.

Inside the cluster, `apps/base/vllm-router` (the vLLM Production Stack router) points
at that box as a **static external backend** and exposes it at `vllm.int.harville.dev`
(so Open WebUI sees the model). Today it fronts a single backend (`qwen3-8b`); add
more `--static-backends` entries to fan out to additional external endpoints.

> History: this used to run in-cluster on two GPU nodes (a WSL box + a DGX Spark)
> with `nvidia-device-plugin`, hostNetwork, and per-node taints. The DGX was retired
> and the WSL box moved out of the cluster during the Talos rebuild, so all of that
> (device plugin, RuntimeClass, `dedicated=gpu` taint, `scripts/gpu.sh`) is gone.

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

# Cluster access + lifecycle (from Omni, not this repo)
omnictl kubeconfig --cluster homelab     # (re)fetch kubeconfig
omnictl get machines                     # machine inventory
# Talos/k8s upgrades + node health: drive from the Omni UI (rolling).
```
