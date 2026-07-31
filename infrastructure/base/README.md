# Base Infrastructure Layout

Each folder in `infrastructure/base/` owns one platform concern.

Examples:
- `traefik/`, `metallb/`, `cert-manager/`, `reflector/`: core cluster services
- `issuers/`, `certificates/`: shared TLS plumbing
- `monitoring/`, `metrics-server/`, `longhorn/`: shared operational services
- `cloudnative-pg/`: PostgreSQL operator, metrics, and Grafana dashboard
- `flux-operator/`: Flux status UI and read-only in-cluster MCP server
- `actions-runner-controller/`: in-cluster GitHub Actions runner
- `sources/`: Flux source objects consumed by releases elsewhere in the repo
- `namespaces/`: shared namespace definitions

The intent is that these manifests are reusable and not tied to a single app.

HelmReleases use `CreateReplace` for CRDs during both install and upgrade. This
keeps chart-owned CRDs current under Flux; Helm's normal upgrade behavior skips
files in a chart's `crds/` directory.
