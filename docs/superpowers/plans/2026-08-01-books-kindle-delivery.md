# Books Kindle Delivery Implementation Plan

> **Execution note:** Use `superpowers:executing-plans` to implement this plan task-by-task. Apply `superpowers:test-driven-development` to the manifest assertions and `superpowers:verification-before-completion` before reporting success.

**Goal:** Deploy Shelfmark at `books.harville.dev` and Calibre-Web-Automated (CWA) at `calibre.int.harville.dev` so an authorized user can search for a book, download it into CWA, and have CWA send it to Kindle once the Kindle delivery address is added.

**Architecture:** Run CWA and Shelfmark as two containers in one `Recreate` Deployment so both can mount the same Longhorn RWO ingest PVC and preserve filesystem event delivery. Keep CWA management internal behind Authentik ForwardAuth. Expose Shelfmark publicly with its native Authentik OIDC login. Store application state on separate PVCs and all credentials in SOPS/age Secrets.

**Stack:** Kubernetes manifests, Flux Kustomize and image automation, Authentik blueprints, SOPS/age, Traefik, Longhorn.

---

## Task 1: Add a failing render check, then create the books workload

**Files:**

- Create: `apps/base/books/kustomization.yaml`
- Create: `apps/base/books/deployment.yaml`
- Create: `apps/base/books/services.yaml`
- Create: `apps/base/books/pvcs.yaml`
- Create: `apps/base/books/ingresses.yaml`

**Step 1: Verify the app overlay does not exist yet**

Run:

```bash
test ! -e apps/base/books/kustomization.yaml
```

Expected: exit 0 before implementation.

**Step 2: Create the Kustomization and storage resources**

Create four RWO Longhorn PVCs:

- `books-cwa-config`, 5Gi, `longhorn-retain`
- `books-library`, 50Gi, `longhorn-retain`
- `books-ingest`, 10Gi, `longhorn`
- `books-shelfmark-config`, 2Gi, `longhorn-retain`

List the deployment, services, PVCs, and ingresses from the Kustomization and set `namespace: apps`.

**Step 3: Create the two-container Deployment**

Use one replica and `strategy.type: Recreate`. Configure:

- CWA image `ghcr.io/crocodilestick/calibre-web-automated:v4.0.6` with a Flux marker, port 8083, `PUID=1000`, `PGID=1000`, `TZ=America/Chicago`, and mounts at `/config`, `/calibre-library`, and `/cwa-book-ingest`.
- Shelfmark image `ghcr.io/calibrain/shelfmark:v1.3.5` with a Flux marker, port 8084, `PUID=1000`, `PGID=1000`, `TZ=America/Chicago`, `AUTH_METHOD=oidc`, Authentik discovery URL, group-based admin, auto-provision, secure cookies, automatic OIDC redirect, disabled local auth, `BOOKS_OUTPUT_MODE=folder`, `INGEST_DIR=/books`, and `CALIBRE_WEB_URL=https://calibre.int.harville.dev`.
- Map Shelfmark's `OIDC_CLIENT_ID` and `OIDC_CLIENT_SECRET` from `books-oidc` Secret keys.
- Mount `books-smtp` read-only at `/run/secrets/books-smtp`; this is an operator-accessible source for CWA's one-time SMTP UI configuration because CWA does not read SMTP credentials from environment variables.
- Mount `books-ingest` into both containers at their respective ingest paths.
- Use CWA `/` and Shelfmark `/api/health` for startup/readiness/liveness probes with startup thresholds long enough for first initialization.
- Set resource requests and memory limits suitable for Calibre conversion and Shelfmark browser/source work.

**Step 4: Create Services and Ingresses**

Create separate ClusterIP Services selecting the shared pod:

- `calibre-web-automated`: port 8083
- `shelfmark`: port 8084

Create:

- Public `books.harville.dev`, `traefik-public`, routed to Shelfmark. Do not add ForwardAuth because Shelfmark owns its OIDC session.
- Internal `calibre.int.harville.dev`, `traefik-internal`, routed to CWA with `apps-authentik-forwardauth@kubernetescrd`.
- Both Ingresses must include a TLS entry whose placeholder secret is replaced by the cluster app Kustomization.

**Step 5: Render and assert the workload**

Run:

```bash
kubectl kustomize apps/base/books >/tmp/books-rendered.yaml
rg -q 'host: books\.harville\.dev' /tmp/books-rendered.yaml
rg -q 'host: calibre\.int\.harville\.dev' /tmp/books-rendered.yaml
rg -q 'ghcr.io/crocodilestick/calibre-web-automated:v4\.0\.6' /tmp/books-rendered.yaml
rg -q 'ghcr.io/calibrain/shelfmark:v1\.3\.5' /tmp/books-rendered.yaml
```

Expected: all commands exit 0.

## Task 2: Add Authentik authorization and OIDC configuration

**Files:**

- Modify: `apps/base/authentik/blueprint.yaml`
- Modify: `apps/base/authentik/helmrelease.yaml`

**Step 1: Establish failing configuration assertions**

Run:

```bash
! rg -q 'name: Books Users' apps/base/authentik/blueprint.yaml
! rg -q 'name: Shelfmark Provider' apps/base/authentik/blueprint.yaml
! rg -q 'name: Calibre Web Automated Provider' apps/base/authentik/blueprint.yaml
```

Expected: all commands exit 0 before implementation.

**Step 2: Add the Books Users group and Shelfmark OIDC application**

Add a confidential Authentik OAuth2/OIDC provider using `BOOKS_OIDC_CLIENT_ID` and `BOOKS_OIDC_CLIENT_SECRET` from the environment, the existing OpenID/email/profile mappings, and the existing custom groups scope. Use strict redirect URI:

```text
https://books.harville.dev/api/auth/oidc/callback
```

Create the `books` application and allow either `Books Users` or `authentik Admins`.

**Step 3: Add internal CWA ForwardAuth**

Create a `forward_single` proxy provider for `https://calibre.int.harville.dev`, an application restricted to `authentik Admins`, and add the provider to the embedded outpost.

**Step 4: Make the OIDC secret available to Authentik**

Add `books-oidc` to `global.envFrom` in the Authentik Helm values. The cluster Kustomization will add the encrypted-secret MAC as a rollout annotation.

**Step 5: Assert blueprint contents and render Authentik**

Run:

```bash
rg -q 'name: Books Users' apps/base/authentik/blueprint.yaml
rg -q 'name: Shelfmark Provider' apps/base/authentik/blueprint.yaml
rg -q 'url: https://books.harville.dev/api/auth/oidc/callback' apps/base/authentik/blueprint.yaml
rg -q 'external_host: https://calibre.int.harville.dev' apps/base/authentik/blueprint.yaml
kubectl kustomize apps/base/authentik >/tmp/authentik-rendered.yaml
```

Expected: all commands exit 0.

## Task 3: Create encrypted credentials and compose the app into the cluster

**Files:**

- Create: `clusters/homelab/apps/secrets/books-oidc.yaml`
- Create: `clusters/homelab/apps/secrets/books-smtp.yaml`
- Modify: `clusters/homelab/apps/kustomization.yaml`

**Step 1: Confirm local SOPS encryption is usable**

Run:

```bash
sops --version
```

Expected: SOPS is installed. Do not print, decrypt, or echo credential values during implementation.

**Step 2: Generate and immediately encrypt the OIDC Secret**

Create a Kubernetes Secret named `books-oidc` in `apps` with randomly generated values for:

- `BOOKS_OIDC_CLIENT_ID`
- `BOOKS_OIDC_CLIENT_SECRET`

Encrypt it immediately with the repo's `.sops.yaml` age recipient and verify that no plaintext client value remains.

**Step 3: Create and immediately encrypt the SMTP Secret**

Create a Kubernetes Secret named `books-smtp` in `apps` containing the user-supplied Cloudflare token as `CLOUDFLARE_SMTP_TOKEN`. Encrypt it immediately and verify the file contains `ENC[AES256_GCM` rather than the plaintext token. Never include the token in logs, documentation, diffs, or the final response.

**Step 4: Register resources and roll consumers on changes**

Add both Secret files and `../../../apps/base/books` to the cluster apps Kustomization. Add replacements:

- `books-oidc` `sops.mac` to the books Deployment pod annotation.
- `books-oidc` `sops.mac` to Authentik global pod annotations.
- `books-smtp` `sops.mac` to the books Deployment pod annotation.

Use `options.create: true` for each target field.

**Step 5: Render the complete apps composition**

Run:

```bash
kubectl kustomize clusters/homelab/apps >/tmp/apps-rendered.yaml
rg -q 'name: books-oidc' /tmp/apps-rendered.yaml
rg -q 'name: books-smtp' /tmp/apps-rendered.yaml
rg -q 'books-oidc-mac:' /tmp/apps-rendered.yaml
rg -q 'books-smtp-mac:' /tmp/apps-rendered.yaml
```

Expected: all commands exit 0 and no secret plaintext appears in the rendered output.

## Task 4: Add Flux image automation

**Files:**

- Create: `infrastructure/base/flux-image-automation/books.yaml`
- Modify: `infrastructure/base/flux-image-automation/kustomization.yaml`

**Step 1: Establish the missing-resource check**

Run:

```bash
test ! -e infrastructure/base/flux-image-automation/books.yaml
```

Expected: exit 0 before implementation.

**Step 2: Add repositories and stable-version policies**

Create ImageRepository and ImagePolicy pairs for:

- `ghcr.io/crocodilestick/calibre-web-automated`, tags `vX.Y.Z`, semver `>=4.0.6 <5.0.0`.
- `ghcr.io/calibrain/shelfmark`, tags `vX.Y.Z`, semver `>=1.3.5 <2.0.0`.

Exclude signature tags and register the manifest in the image automation Kustomization.

**Step 3: Render image automation**

Run:

```bash
kubectl kustomize infrastructure/base/flux-image-automation >/tmp/books-images-rendered.yaml
rg -q 'name: calibre-web-automated' /tmp/books-images-rendered.yaml
rg -q 'name: shelfmark' /tmp/books-images-rendered.yaml
```

Expected: all commands exit 0.

## Task 5: Document the first-run workflow and constraints

**Files:**

- Create: `docs/apps/books.md`
- Modify: `docs/apps/README.md`

**Step 1: Write the operator runbook**

Document:

1. Add the wife to Authentik `Books Users`.
2. Sign in to Shelfmark at `books.harville.dev` and configure only lawful, authorized content sources in its UI.
3. Sign in to internal CWA and complete initial library setup.
4. Copy the mounted Cloudflare token from `/run/secrets/books-smtp/cloudflare-smtp-token` into CWA's mail UI without persisting it anywhere else.
5. Configure SMTP as host `smtp.mx.cloudflare.net`, port 465, implicit TLS/SSL, username `api_token`, sender `books@harville.dev`, and the token as password.
6. Leave the Kindle delivery address blank until it is known. Later set it on the intended CWA user, enable auto-send, and approve `books@harville.dev` in Amazon's Personal Document Settings.
7. Note Cloudflare Email Service's 5 MiB total-message limit, which may prevent larger ebooks from being delivered through this SMTP path.
8. Test with a public-domain EPUB: download in Shelfmark, confirm CWA ingest, then confirm Kindle delivery after the address is configured.

Do not put the SMTP token or OIDC values in the runbook.

**Step 2: Link the runbook from the apps index**

Add a concise Books entry to `docs/apps/README.md`.

**Step 3: Verify documentation contains no credential**

Run a fixed-string search for the supplied token across tracked and untracked files, excluding the encrypted Secret only for the encrypted ciphertext check. Expected: no plaintext matches anywhere.

## Task 6: Full validation and review

**Files:** all files above.

**Step 1: Run repository validation**

Run:

```bash
uvx pre-commit run --all-files
kubectl kustomize clusters/homelab/apps >/dev/null
kubectl kustomize clusters/homelab/infra >/dev/null
kubectl kustomize clusters/homelab/flux-system >/dev/null
```

Expected: all commands exit 0.

**Step 2: Inspect generated resources**

Confirm:

- The public route targets Shelfmark only.
- The internal route targets CWA and includes ForwardAuth.
- Both containers mount the same ingest claim.
- Authentik receives the OIDC Secret and both workloads roll when their Secrets change.
- No Kindle delivery address is configured.
- No plaintext credentials appear in the diff or repository.

**Step 3: Review the final diff**

Run:

```bash
git status --short
git diff --check
git diff --stat
git diff -- apps/base/books apps/base/authentik clusters/homelab/apps infrastructure/base/flux-image-automation docs/apps
```

Expected: only the intended implementation files are changed, with no whitespace errors or plaintext secrets.

**Step 4: Commit the implementation if repository write approval is available**

Commit the complete reviewed change with a concise message such as:

```bash
git add apps/base/books apps/base/authentik/blueprint.yaml apps/base/authentik/helmrelease.yaml clusters/homelab/apps infrastructure/base/flux-image-automation docs/apps docs/superpowers/plans/2026-08-01-books-kindle-delivery.md
git commit -m "feat: deploy Shelfmark and Calibre book workflow"
```

Do not push or reconcile Flux unless the user separately requests those external state changes.
