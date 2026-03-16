# Longhorn Migration

This cluster is moving from `local-path` to Longhorn-backed storage.

## Default storage class

- `longhorn-ha` is the intended default StorageClass for new PVCs.
- `local-path` must remain installed for existing volumes until each workload is migrated, but it should not stay default.
- The Longhorn chart-managed `longhorn` StorageClass stays non-default. The repo-owned `longhorn-ha` class is the one to use for future claims.

## Active PVCs to migrate

- `monitoring/kube-prometheus-stack-grafana` 10Gi
- `apps/authelia` 2Gi
- `apps/openwebui` 2Gi
- `apps/openwebui-ollama` 50Gi
- `apps/paperless` 50Gi
- `apps/data-paperless-postgresql-0` 8Gi

## Stale PVCs

- `apps/paperless-data` 4Gi
- `apps/paperless-media` 50Gi

These two Paperless claims are leftovers from the older `paperless-ngx-0.24.1` chart layout and are not mounted by any current pod. Do not migrate them as active data; inspect and delete them after the live Paperless migration is complete and the contents are confirmed unnecessary.

## Migration rules

- Do not edit the `storageClassName` of a bound PVC in place.
- Migrate one workload at a time.
- For each workload:
  1. Create a replacement PVC on `longhorn-ha`.
  2. Stop the workload so the source volume is quiescent.
  3. Copy data from old PVC to new PVC with a temporary migration pod or job.
  4. Update manifests to point at the new claim or recreate the workload PVC on Longhorn.
  5. Start the workload and verify application health before deleting the old PVC.

## Suggested order

1. Grafana
2. Authelia
3. OpenWebUI
4. Ollama data
5. Paperless app data
6. Paperless PostgreSQL

## Generic copy job

Use a one-off pod or job with both PVCs mounted. Example:

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: pvc-copy-example
  namespace: apps
spec:
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: copier
          image: alpine:3.21
          command:
            - /bin/sh
            - -lc
            - |
              cd /source
              tar cpf - . | tar xpf - -C /target
          volumeMounts:
            - name: source
              mountPath: /source
              readOnly: true
            - name: target
              mountPath: /target
      volumes:
        - name: source
          persistentVolumeClaim:
            claimName: old-claim-name
        - name: target
          persistentVolumeClaim:
            claimName: new-claim-name
```

## Application notes

- Grafana is the simplest first cutover because it is a single PVC and the chart can tolerate brief downtime.
- Authelia currently uses a PVC directly; once it is on Longhorn, move its session and storage backends off single-pod local state before adding replicas.
- OpenWebUI has two PVCs to migrate: the main app PVC and the Ollama model store.
- Paperless now uses the single `paperless` claim for app files. The old `paperless-data` and `paperless-media` claims are not mounted by the current deployment.
- `data-paperless-postgresql-0` is a StatefulSet `volumeClaimTemplate` PVC. Treat it as a database migration, not a generic file copy. The clean path is `pg_dump` or a controlled PostgreSQL data-dir cutover with downtime.
