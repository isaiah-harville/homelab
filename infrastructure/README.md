# Infrastructure Layout

`infrastructure/` is the platform layer.

`infrastructure/base/` contains reusable cluster capabilities and shared services such as:
- ingress
- cert-manager
- shared certificates
- storage
- monitoring
- cluster resource metrics
- GitHub Actions runners
- Flux-adjacent source definitions

These are the building blocks that app workloads depend on.
