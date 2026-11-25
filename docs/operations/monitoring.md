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
`infrastructure/monitoring/kube-prometheus-stack/app/helmrelease.yaml`. Review a dashboard before
changing its revision; a newer Grafana.com revision is external code and may
change queries or required metrics.

## Alerts

Alertmanager emails every `warning` and `critical` alert, and again when it
resolves (routing and recipient are in the SOPS-encrypted
`alertmanager-config.sops.yaml`). Three kinds of rule feed it:

- **Metric rules:** `PrometheusRule` resources labelled
  `release: kube-prometheus-stack`, in any namespace. Cluster-wide ones are in
  `infrastructure/monitoring/kube-prometheus-stack/app/homelab-alerts.yaml`;
  app-specific ones live beside the app (for example
  `apps/media/books/app/monitoring.yaml`).
- **Uptime checks:** `blackbox-exporter` (`infrastructure/monitoring/blackbox-exporter`)
  fetches URLs for Prometheus. An app declares a `Probe` (prober
  `blackbox-exporter.monitoring.svc:9115`, module `http_2xx`, label
  `release: kube-prometheus-stack`) and alerts on `probe_success == 0`. Pair it
  with an `absent(probe_success{job="..."})` rule so a broken exporter cannot
  silence the alert.
- **Log rules:** Loki's ruler evaluates LogQL alert rules and sends them to
  Alertmanager. Put the rules in a ConfigMap labelled `loki_rule: "true"` in any
  namespace, with the rule file as a data key; Loki's sidecar loads it within a
  minute. Use these for failures that only appear in logs. Check what is loaded
  with:

  ```bash
  kubectl get --raw /api/v1/namespaces/monitoring/services/loki:3100/proxy/loki/api/v1/rules
  ```
