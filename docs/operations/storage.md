# Storage

Longhorn provides the default Kubernetes StorageClass. Talos machine patches
prepare eligible disks and make their mount points visible to Longhorn.

## Node preparation

A storage node needs the matching machine configuration:

- `longhorn-disk.yaml` defines and mounts the storage volume.
- `longhorn-storage-node.yaml` labels the node for disk creation.
- the Talos image includes the system extensions required by Longhorn.

Apply storage patches only when the selected disk layout is correct for that
machine. Installation selectors and storage selectors are machine-specific.

## Application storage

Applications can omit `storageClassName` to use the default Longhorn class or
set it explicitly. Replicas are spread across nodes with strict anti-affinity.

Avoid stacking two independent replication layers without a reason. Services
that already store their data on Longhorn generally use a single application
replica unless they need application-level availability semantics.

## Verification

```bash
kubectl get storageclass
kubectl -n longhorn-system get pods
kubectl get persistentvolumeclaims -A
kubectl get persistentvolumes
```

Use the Longhorn UI or its Kubernetes resources to inspect replica placement,
disk capacity, and degraded volumes.
