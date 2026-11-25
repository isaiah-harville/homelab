# Upgrades: Omni, Talos and Kubernetes

Three version pins move the platform, and they have to move in order. Each
step is a Git change; nothing is upgraded by hand.

| What | Pinned in | Applied by |
|---|---|---|
| Omni, Dex | `omni-server/compose.yaml` | [`ansible/omni-host`](../ansible/omni-host/README.md) on the Omni host |
| Talos | `terraform/omni/locals.tf` (`talos_version`) | Terraform CI on merge, then Omni rolls nodes |
| Kubernetes | `terraform/omni/locals.tf` (`k8s_version`) | Terraform CI on merge, then Omni rolls nodes |
| Local CLIs | Homebrew (`siderolabs/tap/omnictl`, `talosctl`) | you |

Mirror the Talos and Kubernetes pins in `talos/omni/cluster-template.yaml`.

## Order

1. **Omni first.** Each Omni release caps the Talos minor it will upgrade to,
   so a newer Talos waits on a newer Omni. Bump the image in
   `omni-server/compose.yaml`, merge, then run the playbook. It backs up the
   host, starts the new version and waits for Omni's and Dex's `/healthz`.
   Read the release notes first: Omni refuses to start with a removed flag
   (v1.14 removed `--auth-oidc-client-secret`, for example).
2. **Then Talos.** Change only `talos_version`. Omni rejects an update that
   changes Talos and Kubernetes together ("the Talos and Kubernetes versions
   cannot be updated at the same time"), and the apply fails without changing
   anything. Check that the system extensions in `terraform/omni/locals.tf`
   exist for the new release at
   `https://factory.talos.dev/version/<version>/extensions/official`.
3. **Then Kubernetes**, once every node reports the new Talos version
   (`omnictl get clusterstatus homelab`, or `kubectl get nodes -o wide`). The
   new Kubernetes must be within the range the Talos release supports.

Omni rolls each step one node at a time and Longhorn rebuilds that node's
replicas after it reboots. Before merging a Talos or Kubernetes change, check
that every attached Longhorn volume is healthy; let it recover between nodes
if a node drops on its own mid-rollout.

## Patch releases

Flux image automation commits Omni (`~1.14`) and Dex (`~2.46`) patch releases
to `omni-server/compose.yaml` on `main` as `chore(omni): update Omni host
images`. Nothing changes on the host until the playbook runs. Minor versions
are deliberate edits: change the ImagePolicy range in
`infrastructure/flux-system/image-automation/app/omni-host.yaml` along with
the pin.

## Clients and the Terraform provider

- **`omnictl` must match Omni's API.** Omni v1.11 moved its API to v3; an older
  client fails with `client API version mismatch`. Upgrade `omnictl` with Omni
  (`brew upgrade siderolabs/tap/omnictl`), and `talosctl` with Talos.
- **The Terraform provider** (`terraform/omni/versions.tf`) has to speak the
  same API. Review its release notes on a bump and read the plan for any
  replaced resource: see
  [Omni resource identity](../decisions/omni-resource-identity.md) for the
  `.id` versus `.name` change in `0.1.0-beta.0`.

## Rollback

- **Omni:** restore the encrypted backup the playbook took before the upgrade
  (`omni-server/backups/`) and pin the previous image. Omni migrates its
  databases on start, so changing the tag back alone is not enough.
- **Talos / Kubernetes:** revert the pin in a PR. Omni rolls nodes back the
  same way it rolled them forward.
