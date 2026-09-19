# Flux layout and moving things safely

Apps and infrastructure share one shape: `<tree>/<namespace>/<component>/`
holds a `ks.yaml` (the component's own Flux `Kustomization`, in `flux-system`)
and an `app/` directory with what it applies. The roots in
`clusters/homelab/flux-system/` only create namespaces and those
per-component Kustomizations.

## Why moves need care

Flux prunes whatever a Kustomization stops rendering. Moving a component
between Kustomizations, renaming its Kustomization, or changing its namespace
therefore deletes the old copy, and:

- a PersistentVolumeClaim goes with it, and so does its volume unless the
  PersistentVolume is `Retain`;
- a HelmRelease is uninstalled, which for charts that template their CRDs
  (Longhorn, CloudNativePG, cert-manager) deletes every custom resource of
  those kinds;
- a raw-manifest operator (RabbitMQ, Barman Cloud plugin) loses its CRDs the
  same way.

## Changing which Kustomization owns something

1. Turn pruning off on the parent that is letting go (`prune: false`, or the
   `kustomize.toolkit.fluxcd.io/prune: disabled` annotation on the object when
   the parent is the operator-managed `flux-system`). Make that live first.
2. Push the change; let the new owner apply the objects under their existing
   names.
3. Once the old parent's inventory no longer lists them, turn pruning back on
   and drop the annotation.

## Moving an app to another namespace

1. Commit the new `targetNamespace` and address changes, then
   `flux suspend ks <app>` before pushing.
2. Reconcile the root `apps` Kustomization and confirm the app's
   `spec.targetNamespace` changed while it is still suspended. Resuming before
   this re-applies the old spec, and the app comes up on fresh empty volumes.
3. Scale the app to zero. For each PVC: set its PV to `Retain`, delete the
   PVC, and set the PV's `claimRef` to the new namespace/name so it is
   pre-bound. Charts that put the namespace in a claim name (SeaweedFS's
   master) need the new name here.
4. `flux resume ks <app>`; the new PVCs bind to the pre-bound volumes. Put the
   original reclaim policy back.

CloudNativePG clusters cannot adopt volumes from another namespace. Restore
them instead: `bootstrap.recovery` from the object store (`externalClusters`
with the old `serverName`), archiving under a new `serverName`. Stop the app,
take a Backup from the primary, then `pg_switch_wal()` and wait until
`pg_stat_archiver.last_archived_wal` is at or past the backup's `endWal`
before the old cluster is deleted. Otherwise the restore cannot reach a
consistent point.
