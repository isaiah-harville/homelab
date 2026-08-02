# Seerr Auto-Approval Design

## Goal

Users admitted to Seerr through Authentik's `media` group can request standard
movies and TV shows without a second approval step.

## Design

The Seerr preparation script will set `main.defaultPermissions` to the bitwise
combination of Seerr's `REQUEST` and generic `AUTO_APPROVE` permissions. The
generic permission covers both movie and TV requests while avoiding unrelated
administrative, advanced-request, and 4K permissions.

New OIDC users inherit the policy from Seerr settings. Existing non-admin users
will have the `AUTO_APPROVE` bit added without replacing any permissions they
already hold. This migration is idempotent and leaves administrators unchanged.

The existing pending request will be approved through Seerr's API after rollout,
so Seerr performs its normal Radarr handoff. The database will not be edited to
force the request state.

## Boundaries

- Authentik remains the admission boundary; only members of `media` can access
  Seerr.
- Standard movies and TV are auto-approved.
- 4K requests and Seerr administrative permissions are not granted.
- Prowlarr and Radarr indexer health are separate from approval policy and must
  still be healthy for an approved request to download.

## Verification

Validate the rendered Kustomize output and repository checks, reconcile Flux,
then confirm that Seerr reports the default permission value and that the
existing user has the auto-approve bit. Approve the pending request through the
API and trace it into Radarr and qBittorrent, reporting any downstream blocker
separately.
