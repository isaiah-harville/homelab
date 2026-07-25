# Terraform — Omni cluster

Manages the **homelab** Omni cluster (cluster, machine sets, machine assignments,
config patches) with the [`siderolabs/omni`](https://registry.terraform.io/providers/siderolabs/omni)
provider. This is the GitOps answer for the Omni cluster template: instead of
running `omnictl cluster template sync` by hand, a **self-hosted GitHub Actions
runner** (in-cluster, ARC) runs `terraform plan` on PRs and `terraform apply` on
merge to `main`.

> The provider is **alpha** (`0.1.0-alpha.3`). `talos/omni/cluster-template.yaml`
> stays as the proven fallback — and Terraform **reads the same patch files**
> under `talos/omni/patches/`, so patch content has a single source of truth.
> Don't let the two topologies drift.

## Layout

| File | What |
|------|------|
| `versions.tf`  | Provider pin + **Kubernetes state backend** (state Secret in-cluster) |
| `providers.tf` | `omni` provider (endpoint + SA key from env) |
| `locals.tf`    | Topology: node UUIDs, versions, per-machine patch map |
| `cluster.tf`   | `omni_cluster`, control-plane + workers machine sets, node assignments |
| `patches.tf`   | `omni_config_patch` per the template (reads `../../talos/omni/patches/*.yaml`) |

## How it runs (CI)

`.github/workflows/terraform.yaml` targets `runs-on: homelab` — the ARC runner in
`infrastructure/base/actions-runner-controller`. The runner pod:

- gets `OMNI_ENDPOINT` + `OMNI_SERVICE_ACCOUNT_KEY` via `envFrom` the `omni-terraform`
  secret (provider auth — no GitHub secrets needed);
- runs as the `terraform` ServiceAccount with `KUBE_IN_CLUSTER_CONFIG=true`, so the
  **Kubernetes state backend** reads/writes its state Secret in-cluster (RBAC in
  `terraform-rbac.yaml`). No state credentials to manage.

PR → `fmt`/`validate`/`plan`. Merge to `main` → `apply`.

The ARC resources and all three SOPS secrets are enabled in
`clusters/homelab/infra/kustomization.yaml`. Verify the runner is online before
depending on this workflow:

```bash
kubectl -n arc-runners get pods
```

> Do not merge the apply workflow to `main` until the existing Omni resources
> have been imported and `terraform plan` is clean.

## One-time setup

### 1. State backend (Kubernetes — nothing to provision)

State lives in a Secret (`tfstate-default-omni-homelab`) in the `arc-runners`
namespace, with a Lease (`lock-omni-homelab`) for locking. Both are created
automatically. The runner reaches them via the `terraform` ServiceAccount
(`terraform-rbac.yaml`); nothing to create by hand.

> Why not SeaweedFS S3: Terraform's S3 backend (AWS SDK v2) writes state with a
> chunked `STREAMING-UNSIGNED-PAYLOAD-TRAILER` upload that SeaweedFS rejects
> (403 `InvalidAccessKeyId`) — reads work, writes don't, with no client knob to
> disable it. The Kubernetes backend sidesteps that and suits the in-cluster runner.

### 2. Maintain the runner secrets

The two files under
`clusters/homelab/infra/secrets/actions-runner-controller/` are already
SOPS-encrypted:

```bash
sops clusters/homelab/infra/secrets/actions-runner-controller/github-config.yaml
sops clusters/homelab/infra/secrets/actions-runner-controller/omni-terraform.yaml
```

Editing requires the age identity matching `.sops.yaml`.

- **github-config** — a `github_token` PAT (classic, `repo` scope) that registers the
  runner (a GitHub App with repo Administration r/w + Actions read also works).
- **omni-terraform** — a dedicated Omni service account:
  `omnictl serviceaccount create --role Admin terraform`.

### 3. Verify ARC

ARC is selected by `clusters/homelab/infra/kustomization.yaml`. Confirm both the
controller and runner scale set reconcile, then check the repository's
Settings → Actions → Runners:

```bash
flux get helmreleases -A
kubectl -n arc-systems get pods
kubectl -n arc-runners get pods
```

### 4. Adopt the existing cluster (import — already done)

The live cluster (created via `omnictl cluster template sync`) has been imported
into the Kubernetes-backend state and `terraform plan` reports **no changes**, so CI
is safe to `apply`. The steps below are for **re-import** if state is ever lost.

Locally you drive the backend with a kubeconfig; the provider needs the Omni env:

```bash
cd terraform/omni
export OMNI_ENDPOINT=https://omni.int.harville.dev/
export OMNI_SERVICE_ACCOUNT_KEY=<omni SA key>
export KUBE_CONFIG_PATH=$HOME/.kube/config    # backend talks to the cluster API
terraform init
terraform fmt -check -recursive
terraform validate

terraform import omni_cluster.homelab homelab
terraform import omni_machine_set.control_plane homelab-control-planes
terraform import omni_machine_set.workers       homelab-workers
# machine-set nodes: import ID is the bare machine UUID
terraform import 'omni_machine_set_node.control_plane["4c4c4544-0030-5910-805a-c6c04f503133"]' 4c4c4544-0030-5910-805a-c6c04f503133
# …repeat for each control-plane + worker node…
# config patches: import ID is the Omni ConfigPatch id (weight-scope-name),
# e.g. 200-cluster-homelab-allow-scheduling, 400-cm-<uuid>-install-nvme,
# 401-cm-<uuid>-longhorn-disk — list them with `omnictl get configpatches`.
```

Then `terraform plan` until it reports **no changes** (adjust HCL to match reality,
never the other way around). Only once plan is clean is it safe to let CI `apply`.

> If the patch `data` shows diffs after import, the live patches drifted from the
> repo files — run `omnictl cluster template sync -f talos/omni/cluster-template.yaml`
> once to re-push them (comment-only changes don't touch nodes), then re-plan.

The Kubernetes backend locks via a Lease; the workflow concurrency group also
serializes CI runs. Don't run a local apply while CI is applying.

> Machine-set and config-patch IDs come from Omni: `omnictl get machinesets`,
> `omnictl get machinesetnodes`, `omnictl get configpatches`. The control-plane set
> id is `homelab-control-planes`, workers `homelab-workers`.

## Day-2

Change topology/versions/patches → open a PR → review the `plan` → merge → CI
applies. Keep `cluster-template.yaml` in step until the provider is stable enough
to retire it.

### If state is lost

Omni is the source of truth, so nothing is destroyed — recreate state by repeating
the **import** step against the live cluster.
