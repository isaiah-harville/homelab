# Storage

Longhorn provides the default Kubernetes StorageClass. Talos machine patches
prepare eligible disks and make their mount points visible to Longhorn.

## Node preparation

A storage node needs the matching machine configuration:

- `longhorn-disk.yaml` defines and mounts a dedicated storage volume.
- `longhorn-root-disk.yaml` exposes storage on an intentionally selected
  single-disk node without claiming a second disk.
- `longhorn-storage-node.yaml` labels the node for disk creation.
- the Talos image includes the system extensions required by Longhorn.

Apply storage patches only when the selected disk layout is correct for that
machine. Installation selectors and storage selectors are machine-specific.

## Application storage

Applications can omit `storageClassName` to use the default Longhorn class or
set it explicitly. Replicas are spread across nodes with strict anti-affinity.

Use `longhorn-retain` for new data whose backing volume should survive an
accidental PVC deletion. The default `longhorn` class retains its normal
`Delete` reclaim policy. The retained class also uses best-effort data locality,
so Longhorn prefers one replica on the workload node without making attachment
depend on it. A StorageClass cannot be changed on an existing PVC; migrating
existing claims requires a planned data copy or restore.

Avoid stacking two independent replication layers without a reason. Services
that already store their data on Longhorn generally use a single application
replica unless they need application-level availability semantics.

## Recovery points

The default recurring-job group applies these jobs to volumes that do not have
a more specific recurring-job assignment:

- daily snapshots at 02:15 UTC, retaining seven per volume;
- filesystem trim at 04:15 UTC each Sunday.

Snapshots remain inside Longhorn. They help with short-term rollback but do not
protect against loss of the cluster or its storage nodes. Configure an external
S3-compatible or NFS backup target before adding a recurring `backup` job.
SeaweedFS in this cluster is backed by Longhorn, so using it as Longhorn's only
backup target would create a circular dependency rather than disaster recovery.

## Verification

```bash
kubectl get storageclass
kubectl -n longhorn-system get pods
kubectl -n longhorn-system get recurringjobs.longhorn.io
kubectl -n longhorn-system get backuptargets.longhorn.io
kubectl -n longhorn-system get volumes.longhorn.io
kubectl -n longhorn-system get nodes.longhorn.io
kubectl get persistentvolumeclaims -A
kubectl get persistentvolumes
```

Use the Longhorn UI or its Kubernetes resources to inspect replica placement,
disk capacity, degraded volumes, snapshot execution, and backup health. A node
label controls creation of a default disk only; removing the label does not
remove an existing Longhorn disk. Drain and evict replicas in Longhorn before
removing an unintended disk from a node.
