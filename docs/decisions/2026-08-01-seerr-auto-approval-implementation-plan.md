# Seerr Auto-Approval Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Auto-approve standard movie and TV requests made by users admitted to Seerr through Authentik.

**Architecture:** Seerr's init-container preparation script will declare `REQUEST | AUTO_APPROVE` as the default permission mask and idempotently add `AUTO_APPROVE` to existing non-admin users while Seerr is stopped. The existing pending request will then be approved through Seerr's HTTP API so its normal Radarr handoff runs.

**Tech Stack:** Python 3.14, SQLite, Seerr preview, Kubernetes/Kustomize, Flux

## Global Constraints

- Authentik's `media` group remains the only admission boundary.
- Auto-approval covers standard movies and TV shows.
- Do not grant 4K, settings, user-management, or request-management permissions.
- Preserve every existing user permission bit.
- Do not mutate a request directly in SQLite; use Seerr's API.
- Do not retain temporary test scripts in the repository.

---

### Task 1: Declarative Seerr auto-approval

**Files:**
- Modify: `apps/base/media-stack/scripts/seerr_prepare.py`
- Temporary test: `/private/tmp/test_seerr_prepare.py`

**Interfaces:**
- Consumes: `CONFIG_DIRECTORY`, defaulting to `/app/config`; Seerr `settings.json`; optional Seerr `db/db.sqlite3`
- Produces: `main.defaultPermissions = 160`; existing non-admin permissions updated with bit `128`

- [ ] **Step 1: Write the failing behavioral test**

Create `/private/tmp/test_seerr_prepare.py`:

```python
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import tempfile


script = Path("apps/base/media-stack/scripts/seerr_prepare.py").resolve()
with tempfile.TemporaryDirectory() as directory:
    config = Path(directory)
    (config / "db").mkdir()
    (config / "settings.json").write_text(
        json.dumps({"main": {"defaultPermissions": 32}})
    )
    database = sqlite3.connect(config / "db/db.sqlite3")
    database.execute(
        "CREATE TABLE user (id INTEGER PRIMARY KEY, permissions INTEGER NOT NULL)"
    )
    database.executemany(
        "INSERT INTO user (permissions) VALUES (?)",
        [(32,), (2,)],
    )
    database.commit()
    database.close()

    environment = os.environ | {
        "CONFIG_DIRECTORY": str(config),
        "SEERR_OIDC_CLIENT_ID": "test-client",
        "SEERR_OIDC_CLIENT_SECRET": "test-secret",
    }
    subprocess.run(["python3", str(script)], env=environment, check=True)

    settings = json.loads((config / "settings.json").read_text())
    database = sqlite3.connect(config / "db/db.sqlite3")
    permissions = [row[0] for row in database.execute(
        "SELECT permissions FROM user ORDER BY id"
    )]
    database.close()

    assert settings["main"]["defaultPermissions"] == 160
    assert permissions == [160, 2]
```

- [ ] **Step 2: Run the test and verify RED**

Run:

```bash
python3 /private/tmp/test_seerr_prepare.py
```

Expected: FAIL because the current script does not honor `CONFIG_DIRECTORY`, does not set `defaultPermissions`, and does not migrate existing users.

- [ ] **Step 3: Implement the minimal policy**

In `seerr_prepare.py`, resolve the config root from `CONFIG_DIRECTORY`, define the Seerr permission values, and update settings:

```python
REQUEST = 32
AUTO_APPROVE = 128
ADMIN = 2
main["defaultPermissions"] = REQUEST | AUTO_APPROVE
```

If `db/db.sqlite3` exists and contains the `user` table, run this idempotent update while the application is stopped:

```sql
UPDATE user
SET permissions = permissions | 128
WHERE (permissions & 2) = 0
```

- [ ] **Step 4: Run the test and verify GREEN**

Run:

```bash
python3 /private/tmp/test_seerr_prepare.py
```

Expected: PASS with the new-user default, existing ordinary user migration, and unchanged administrator verified.

- [ ] **Step 5: Remove the temporary test and validate manifests**

Run:

```bash
rm /private/tmp/test_seerr_prepare.py
kubectl kustomize clusters/homelab/apps >/dev/null
uvx pre-commit run --all-files
```

Expected: both validation commands exit zero and the temporary test no longer exists.

- [ ] **Step 6: Commit the implementation**

```bash
git add apps/base/media-stack/scripts/seerr_prepare.py
git commit -m "auto-approve Seerr media requests"
```

### Task 2: Rollout and existing request handoff

**Files:**
- No repository files modified

**Interfaces:**
- Consumes: Flux `apps` Kustomization; Seerr request `1`; Seerr API key read inside the pod
- Produces: live Seerr default permissions `160`; existing user's permissions containing bit `128`; request `1` approved through Seerr

- [ ] **Step 1: Push and reconcile GitOps**

Run:

```bash
git push origin main
flux reconcile source git flux-system -n flux-system
flux reconcile kustomization apps -n flux-system --with-source
kubectl -n apps rollout status deployment/seerr --timeout=5m
```

Expected: Flux applies the new revision and the Seerr deployment becomes available.

- [ ] **Step 2: Verify the live authorization state**

Read the settings and database through a read-only Node query inside the Seerr pod. Verify `main.defaultPermissions` equals `160` and the existing non-admin user's permissions contain bit `128`; do not print tokens or passwords.

- [ ] **Step 3: Approve the existing request through Seerr**

Inside the Seerr pod, read `main.apiKey` from `settings.json` into an in-process
variable without printing it and send that value as the `X-Api-Key` header:

```http
POST http://127.0.0.1:5055/api/v1/request/1/approve
X-Api-Key: value held by the in-process variable
```

Expected: HTTP 200 and request status changes from pending to approved.

- [ ] **Step 4: Trace downstream state**

Verify request `1` in Seerr, the matching movie in Radarr, the `movies` category in qBittorrent, and relevant Prowlarr/Radarr logs. Report the exact terminal state, including the already-observed indexer-sync failure if it still prevents a download.
