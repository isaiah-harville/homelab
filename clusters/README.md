# Cluster Layout

`clusters/` contains cluster-specific assembly.

Each cluster folder wires together:
- Flux entrypoints
- cluster-local secrets
- the selected base infrastructure
- the selected app set

`infrastructure/` and `apps/` define reusable building blocks.
`clusters/` decides how those pieces are composed for a specific cluster.
