# Monitoring

`kube-prometheus-stack` supplies Prometheus, Alertmanager, Grafana,
kube-state-metrics, node-exporter, Kubernetes recording rules, alerts, and its
curated Kubernetes dashboards.

## Storage and retention

- Prometheus retains 30 days, capped at 22 GB, on a 25 GiB
  `longhorn-retain` claim.
- Alertmanager retains five days of notification and silence state on a 5 GiB
  `longhorn-retain` claim.
- Grafana uses the existing 10 GiB
  `kube-prometheus-stack-grafana-longhorn` claim. Dashboards listed in Helm
  values are provisioned again on every deployment, so they do not depend only
  on the Grafana database.

The Prometheus and Alertmanager claims are created by their StatefulSets. The
`longhorn-retain` StorageClass prevents their backing Longhorn volumes from
being deleted if a claim is accidentally removed.

## Authentication

`grafana.int.harville.dev` is protected by the Authentik ForwardAuth middleware.
Authentik returns `X-authentik-email`, `X-authentik-name`, and
`X-authentik-groups`; Grafana's auth-proxy mode uses `X-authentik-email` as the
user identity and creates the user on first access. Grafana's login form is
disabled. The chart-generated admin
credential remains internal because the dashboard sidecar uses it to call
Grafana's provisioning API; it is no longer hard-coded or presented as a
second user login.

Authenticated homelab users receive the Grafana organization Admin role. The
Grafana pod also has an ingress NetworkPolicy allowing port 3000 only from the
internal Traefik and monitoring namespaces. Do not expose its ClusterIP through
an ingress that omits Authentik.

## Dashboard coverage

The chart's default dashboards cover Kubernetes control-plane health, resource
usage, workloads, namespaces, nodes, and system components. Additional pinned
dashboards are provisioned for:

- Kubernetes global, namespace, node, and pod views: Grafana IDs 15757–15760.
- Longhorn capacity, volume, node, replica, and engine health: Grafana ID 16888.
- Traefik entrypoint, router, service, request, response-code, and latency
  metrics: Grafana ID 17346.

Both Traefik releases enable Prometheus ServiceMonitors and router labels.
Longhorn's HelmRelease supplies its ServiceMonitor.

Dashboard IDs and revisions are pinned in
`infrastructure/base/monitoring/helmrelease.yaml`. Review a dashboard before
changing its revision; a newer Grafana.com revision is external code and may
change queries or required metrics.
