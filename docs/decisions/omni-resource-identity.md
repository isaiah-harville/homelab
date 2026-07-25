# Omni resource identity

Status: accepted

## Context

The Omni cluster was imported into Terraform rather than created from empty
state. Omni resource IDs encode details that look cosmetic in HCL:

- machine-set IDs derive from cluster and role names
- config-patch IDs include weight, scope, target, and patch name
- per-machine patch names must match the names used by the cluster template

Changing one of those fields can make Terraform plan a replacement instead of
adopting or updating the existing object.

## Decision

Preserve the imported identity scheme:

- allow Omni to use its default machine-set IDs
- keep cluster-wide patch weights aligned with the existing objects
- keep per-machine patch names aligned between `locals.tf` and the Omni cluster
  template
- review any planned replacement of an Omni resource before applying

## Consequences

- Some names and weights cannot be refactored as presentation-only changes.
- The cluster template and Terraform definitions must remain aligned.
- Imports can map cleanly to existing Omni objects.
- A deliberate identity change requires a migration plan rather than an
  ordinary Terraform apply.

Use `omnictl get machinesets`, `omnictl get machinesetnodes`, and
`omnictl get configpatches` to inspect the live IDs before importing or changing
identity fields.
