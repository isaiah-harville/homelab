# Secrets

Kubernetes Secret manifests are encrypted with SOPS and age. Git stores only
ciphertext and SOPS metadata.

## Create or edit a secret

Run SOPS from the repository root so it discovers `.sops.yaml`:

```bash
sops clusters/homelab/apps/secrets/example.yaml
```

For a new manifest, create the Kubernetes Secret under a `secrets/` directory
and encrypt it before staging:

```bash
sops --encrypt --in-place clusters/homelab/apps/secrets/example.yaml
```

Confirm that values under `data` or `stringData` are encrypted before
committing.

## Cluster decryption

Flux reads the age identity from the `sops-age` Secret in `flux-system`.
Kustomizations containing encrypted resources declare the SOPS decryption
provider and Secret reference.

## Rotation

1. Update the encrypted manifest with SOPS.
2. Reconcile the owning Flux Kustomization.
3. Restart workloads that read the Secret only at process startup.
4. Revoke the old credential at its issuing system.

Some workloads use a SOPS MAC annotation replacement so encrypted-content
changes trigger a rollout automatically. Reuse that pattern only for workloads
that do not reload Secret data themselves.

## Recovery

Keep the age private key in an encrypted backup outside the cluster and outside
this repository. During cluster recovery, restore it before reconciling
encrypted infrastructure or applications.
