# Base Infrastructure Layout

Each folder in `infrastructure/base/` owns one platform concern.

Examples:
- `traefik/`, `metallb/`, `cert-manager/`, `reflector/`: core cluster services
- `issuers/`, `certificates/`: shared TLS plumbing
- `monitoring/`, `longhorn/`: shared operational services
- `sources/`: Flux source objects consumed by releases elsewhere in the repo
- `namespaces/`: shared namespace definitions

The intent is that these manifests are reusable and not tied to a single app.
