# AGENTS.md

Operational knowledge for working in this repo. Read this before making changes.

## What this is

GitOps repo for a **Talos Linux cluster** (the "homelab" cluster) managed by a
**self-hosted Omni**. **Flux** reconciles everything at the k8s layer from
`clusters/homelab/`. Nothing k8s-side is applied by hand — you change YAML,
commit, and Flux converges the cluster. Don't `kubectl apply` to make a change
stick; edit the repo.

The machine/OS layer is **Talos** (immutable and API-driven; no SSH or mutable
host configuration). Omni applies the lifecycle operations, while
`terraform/omni/` declares the cluster topology and shared Talos patches.

## Layout

```
omni-server/         Self-hosted Omni (Compose stack + runbook) — the management plane
talos/               Talos image schematic + Omni cluster template + machine-config patches
terraform/omni/      Terraform for the Omni cluster (GitOps for the cluster template)
clusters/homelab/    Flux composition (Kustomizations, cluster-specific secrets, patches)
infrastructure/base/ Cluster plumbing: traefik, cert-manager, metallb, longhorn, monitoring, reflector, sources
apps/base/           Reusable app building blocks (HelmRelease + ingress + kustomization)
apps/releases/       Apps deployed from their OWN external git repos (see below)
```

## Provisioning: Talos + Omni

Talos patches under `talos/omni/patches/` provide the declarative machine
configuration.

1. **Omni** (`omni-server/`) is the management plane. It runs in Docker *outside*
   the cluster (must survive a node wipe), retains its independent Dex static
   break-glass login, and terminates the SideroLink WireGuard tunnel machines
   join through. The in-cluster Authentik deployment does not manage Omni/Dex.
   See `omni-server/README.md`.
2. **Talos image** (`talos/image/schematic.yaml`) is an Image Factory schematic
   pinning the system extensions Longhorn needs (`iscsi-tools`, `util-linux-tools`).
3. **Cluster template** (`talos/omni/cluster-template.yaml`) defines the topology
   (3 laptops control-plane/etcd, dl380 + thinkcentre-01 workers) and pins the
   Talos + k8s versions. Machine-config **patches** live in `talos/omni/patches/`:
   - `controlplane-vip.yaml` — floating API VIP **10.1.10.9**.
   - `kubernetes-oidc.yaml` — trust Authentik ID tokens and map its groups with
     the `oidc:` prefix; Kubernetes RBAC remains the authorization boundary.
   - `allow-scheduling.yaml` — run workloads on control-plane nodes (needed for
     Longhorn's 3-replica anti-affinity with only 2 dedicated workers).
   - `install-*.yaml` — per-machine OS disk selectors.
   - `longhorn-disk.yaml` + `longhorn-storage-node.yaml` — claim and label
     dedicated Longhorn disks.
   - `longhorn-root-disk.yaml` + `longhorn-storage-node.yaml` — expose and label
     the intentionally selected single-disk storage nodes.

   Full bring-up runbook: `talos/README.md`. When topology changes, update both
   `talos/omni/cluster-template.yaml` and `terraform/omni/locals.tf`.
4. **Upgrades / node health / reboots** are driven from Omni (rolling, one node at
   a time).

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
`arc-runners`) so they can reach the **LAN-only** Omni. The runner pod gets
`OMNI_*` creds via `envFrom` the `omni-terraform` SOPS secret (+ a `github_token`
PAT in `github-config`), so the workflow needs no GitHub secrets.
`.github/workflows/terraform.yaml`: plan on PR, apply on merge to `main`.
**State** lives in a **Kubernetes Secret** (`tfstate-default-omni-homelab` in
`arc-runners`) via the Terraform `kubernetes` backend — the runner reaches it with
the `terraform` ServiceAccount (`terraform-rbac.yaml`) + `KUBE_IN_CLUSTER_CONFIG`.
Omni is the real source of truth, so lost state is re-`import`ed, never
catastrophic.

The provider is **alpha**. ARC and its SOPS secrets are enabled in
`clusters/homelab/infra/kustomization.yaml`, the live cluster has been imported,
and `terraform plan` is clean — so CI may apply. Full setup and recovery steps are
in `terraform/omni/README.md`. Keep `cluster-template.yaml` as the manual fallback
while the provider remains alpha (Terraform reads the same patch files, so a
one-off `omnictl cluster template sync` after editing patches keeps them aligned).

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

Flux Operator provides controller lifecycle management, status reporting, and
its web UI at `https://flux.int.harville.dev`. The in-cluster
`flux-operator-mcp` service is read-only. Codex uses `.codex/config.toml` and the
local `flux-operator-mcp` binary with the user's kubeconfig; prefer its reporting
and reconcile tools for Flux operations, but keep persistent resource changes in
Git.

Flux Operator owns the Flux controllers and root Git sync through
`flux-instance.yaml`, which follows the supported `2.8.x` distribution. The
former CLI-bootstrap `gotk-components.yaml` and `gotk-sync.yaml` manifests were
removed only after `FluxInstance/flux` reported Ready and `flux trace
kustomization flux-system` confirmed the root object was not managed by Flux.
Do not recreate generated bootstrap manifests alongside the operator-owned
instance.

## Adding an app (the common task)

1. Create `apps/base/<name>/` with:
   - `helmrelease.yaml` — `HelmRelease` in namespace `apps`, with the standard
     `install`/`upgrade` remediation block (copy from `apps/base/openwebui/helmrelease.yaml`).
     Every HelmRelease sets both `install.crds` and `upgrade.crds` to
     `CreateReplace`; this lets Flux update CRDs shipped in a chart's `crds/`
     directory instead of Helm's default upgrade behavior silently skipping
     them.
     Use a semver range that admits compatible updates but stops before the
     chart's next breaking version. Avoid `*` and exact patch pins. Stateful
     systems and `0.x` charts may deliberately use a narrower minor-version
     boundary when their upstream upgrade process requires review.
   - `kustomization.yaml` — `namespace: apps`, lists the resources.
   - `ingress.yaml` (optional) — standalone Ingress (see conventions below).
2. If the chart is from a new Helm repo, add a `HelmRepository` under
   `infrastructure/base/sources/` and register it in that dir's `kustomization.yaml`.
3. Register the app dir (and any secret files) in `clusters/homelab/apps/kustomization.yaml`.

## Apps from external repos (`apps/releases/`)

Most apps in this directory are reconciled from their **own GitHub repositories**.
The common pattern under `apps/releases/<name>/` is:

- `gitrepository.yaml` — a Flux `GitRepository` (in `flux-system`) for the app's repo.
- `release.kustomization.yaml` — a Flux `Kustomization` whose `spec.path` points at a
  deploy dir **inside that external repo** (not this one), `dependsOn` infra +
  certificates. This is why `orion`, `pigeon`, and `swing-thoughts` show up as
  top-level entries in `flux get kustomizations -A`.
- `ingress.yaml` — the Ingress lives here (so it gets the `apps` Ingress patches).

`openvitae` is the exception: its directory contains a `GitRepository` and an
in-repo `HelmRelease` that loads the chart from that source. It does not create a
child Flux Kustomization or a separate repository-defined Ingress.

All release directories are registered in
`clusters/homelab/apps/kustomization.yaml`. For the common pattern, the parent
creates the GitRepository and child Kustomization, and the child reconciles the
external deployment.

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
- **Authentik SSO** on an internal app: annotation
  `traefik.ingress.kubernetes.io/router.middlewares: apps-authentik-forwardauth@kubernetescrd`.
  Don't put forwardauth in front of services that authenticate themselves via API
  (S3 access keys, `docker login`) — clients can't traverse it.
- Headlamp is the deliberate exception: its internal Ingress has no ForwardAuth
  middleware so the UI and short-lived token login remain reachable during an
  Authentik outage. Normal access still uses Headlamp's native Authentik OIDC flow
  and per-user Kubernetes RBAC; see `docs/operations/authentication.md`.
- **Homepage** dashboard discovery: `gethomepage.dev/*` annotations on the Ingress.
- Open WebUI only has the authenticated public route `webui.harville.dev`; do
  not recreate the redundant `webui.int.harville.dev` route.

## TLS / certificates

- One wildcard `Certificate` `harville-wildcard` (`infrastructure/base/certificates/`)
  via cert-manager + the `letsencrypt-dns` ClusterIssuer (Cloudflare DNS-01).
  Covers `*.harville.dev`, `*.int.harville.dev`, `*.harville.ai`, `*.int.harville.ai`,
  `innerswings.com`, `*.innerswings.com`, `pigeonwire.app`, and
  `*.pigeonwire.app`.
- Secret `harville-wildcard-shared-tls` is **reflected** (emberstack reflector) into the
  namespaces listed in the Certificate's `reflector.*` annotations (currently
  `apps,flux-system,monitoring,longhorn-system`). **If you add an app in a new namespace, add that
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
  both in `talos/omni/patches/longhorn-disk.yaml`. Intentionally selected
  single-disk nodes use `longhorn-root-disk.yaml`, which exposes a directory on
  Talos's persistent EPHEMERAL partition without claiming another disk. Every
  storage node also needs `longhorn-storage-node.yaml`, because Longhorn only
  creates disks on labeled nodes. Longhorn needs the `iscsi-tools` +
  `util-linux-tools` system extensions from `talos/image/schematic.yaml`.
- `defaultReplicaCount: 3` + strict anti-affinity → one replica per node, any single
  node can fail with no data loss. Disks auto-create per node (30% reserved).
- The default recurring-job group retains seven daily snapshots and runs weekly
  filesystem trim. These snapshots are local recovery points, not off-cluster
  backups.
- `longhorn-retain` is available for new critical PVCs that should survive an
  accidental claim deletion and uses best-effort data locality. Existing PVCs
  cannot change StorageClass in place.
- Longhorn has no useful disaster-recovery backup until an external S3-compatible
  or NFS target is configured. Do not use the in-cluster, Longhorn-backed SeaweedFS
  service as the only backup target; that is a circular dependency.
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
  root so `.sops.yaml` is picked up). The age **private** key is not in Git; the
  cluster has a copy in the `sops-age` Secret. Keep a secure external backup for
  cluster recovery. Local decryption requires that identity.
- yamllint/pre-commit excludes `secrets/` and `sops/` dirs.
- During a cluster rebuild, restore the `sops-age` Secret in `flux-system` before
  reconciling `infra` or `apps`; both Kustomizations require it for decryption.
- **Rollout-on-secret-change:** `clusters/homelab/apps/kustomization.yaml` has a
  `replacements` block that copies the `authentik-core` Secret's `sops.mac` into
  a pod annotation on the Authentik HelmRelease. Because the MAC changes whenever
  the secret content changes, editing the secret rolls both server and worker
  pods. Reuse this pattern for any app that reads secrets only at startup.

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
- **flux-operator** — Flux status reporting and UI at `flux.int.harville.dev`.
- **flux-operator-mcp** — read-only in-cluster Flux MCP service; Codex uses the
  project-configured local MCP binary.
- **authentik** — HA SSO/OIDC/ForwardAuth provider. Git-managed blueprints own
  application/provider configuration; Omni/Dex remains independent.
- **homepage** — dashboard, auto-populated from `gethomepage.dev/*` ingress annotations.
- **searxng** — self-hosted metasearch; backs Open WebUI's web-search
  (`http://searxng:8080`, see `apps/base/openwebui`).
- **kube-prometheus-stack** — monitoring (Grafana/Prometheus/Alertmanager).
- **metrics-server** — Kubernetes resource metrics for `kubectl top` and consumers.
- **actions-runner-controller** — the `homelab` GitHub Actions runner scale set.
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

# Cluster access + lifecycle
omnictl kubeconfig --cluster homelab     # (re)fetch kubeconfig
omnictl get machines                     # machine inventory
# Terraform declares topology; Omni performs rolling lifecycle operations.
```

## Validation

```bash
uvx pre-commit run --all-files
kubectl kustomize clusters/homelab/apps >/dev/null
kubectl kustomize clusters/homelab/infra >/dev/null
kubectl kustomize clusters/homelab/flux-system >/dev/null
terraform -chdir=terraform/omni fmt -check -recursive
```
