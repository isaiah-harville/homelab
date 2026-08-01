# qBittorrent with NordVPN Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deploy qBittorrent behind a NordVPN-enforced Gluetun kill switch and connect it to Shelfmark with safe 24-hour post-import cleanup.

**Architecture:** A dedicated qBittorrent Deployment contains a native Gluetun sidecar init container and the qBittorrent application container in one pod network namespace. Shelfmark remains in the separate Books Deployment and shares a Longhorn RWX download PVC with qBittorrent at `/data/torrents`; successful imports move to an `imported` category before a tested cleanup job can remove their torrent data.

**Tech Stack:** Kubernetes 1.36, Kustomize, Flux, SOPS/age, Longhorn RWX, Gluetun v3.41.1, LinuxServer qBittorrent 5.2.x, Authentik ForwardAuth, Python 3 standard library, Ruby/Psych manifest validation.

## Global Constraints

- NordVPN uses OpenVPN over UDP with `SERVER_COUNTRIES=United States`.
- NordVPN service credentials and qBittorrent credentials exist only in `clusters/homelab/apps/secrets/qbittorrent.yaml` after SOPS encryption.
- Gluetun is the only container that receives `NET_ADMIN` and `/dev/net/tun`.
- qBittorrent and Books remain separate Deployments so VPN failure cannot make CWA or Shelfmark unavailable.
- Both Deployments exclude `talos-rwj-wvp`, the unreliable DL380.
- qBittorrent and Shelfmark mount the same 50 GiB RWX PVC at `/data/torrents`.
- Automatic cleanup selects only category `imported` with `completion_on` at least 86,400 seconds old and uses qBittorrent's `deleteFiles=true` API behavior.
- The internal Web UI host is exactly `torrent.int.harville.dev`.
- Authentik creates no new group; initial authorization uses the existing `authentik Admins` group.
- Do not configure or enable a third-party Shelfmark content source in Git.
- Do not print supplied or generated credentials in command output, logs, commits, diffs, or documentation.

## File Structure

### New files

- `apps/base/qbittorrent/kustomization.yaml` — compose the application resources and generate the scripts ConfigMap.
- `apps/base/qbittorrent/deployment.yaml` — Gluetun native sidecar and qBittorrent application pod.
- `apps/base/qbittorrent/pvcs.yaml` — retained config and shared download PVCs.
- `apps/base/qbittorrent/services.yaml` — internal Web UI/API Service.
- `apps/base/qbittorrent/ingress.yaml` — internal Authentik-protected route.
- `apps/base/qbittorrent/cleanup-cronjob.yaml` — daily cleanup.
- `apps/base/qbittorrent/scripts/bootstrap.py` — idempotent qBittorrent config writer.
- `apps/base/qbittorrent/scripts/cleanup.py` — qBittorrent API cleanup client.
- `scripts/tests/test_qbittorrent_bootstrap.py` — bootstrap unit tests.
- `scripts/tests/test_qbittorrent_cleanup.py` — cleanup unit tests.
- `scripts/validate_qbittorrent_manifests.rb` — rendered-manifest contract tests.
- `clusters/homelab/apps/secrets/qbittorrent.yaml` — SOPS-encrypted credentials.

### Modified files

- `apps/base/books/deployment.yaml` — qBittorrent client settings and shared download mount.
- `apps/base/authentik/blueprint.yaml` — qBittorrent provider, application, admin binding, and outpost registration.
- `clusters/homelab/apps/kustomization.yaml` — base, Secret, and rollout replacements.
- `infrastructure/base/namespaces/namespaces.yaml` — permit Gluetun in `apps`.
- `infrastructure/base/flux-image-automation/books.yaml` — qBittorrent image policy.

---

### Task 1: Implement and Test the 24-Hour Cleanup Policy

**Files:**
- Create: `apps/base/qbittorrent/scripts/cleanup.py`
- Create: `scripts/tests/test_qbittorrent_cleanup.py`

**Interfaces:**
- Consumes: qBittorrent Web API v2 fields `hash`, `category`, and `completion_on`.
- Produces: `eligible_for_cleanup(torrent: dict, now: int, retention_seconds: int = 86400) -> bool`, `select_cleanup_hashes(torrents: list[dict], now: int) -> list[str]`, and `QBittorrentClient`.

- [ ] **Step 1: Write failing cleanup-selection tests**

Create `scripts/tests/test_qbittorrent_cleanup.py`:

```python
import importlib.util
from pathlib import Path
import unittest

MODULE_PATH = Path(__file__).parents[2] / "apps/base/qbittorrent/scripts/cleanup.py"
SPEC = importlib.util.spec_from_file_location("qbittorrent_cleanup", MODULE_PATH)
cleanup = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(cleanup)


class CleanupSelectionTests(unittest.TestCase):
    def test_selects_only_imported_torrent_at_least_24_hours_old(self):
        now = 200_000
        torrents = [
            {"hash": "eligible", "category": "imported", "completion_on": now - 86_400},
            {"hash": "young", "category": "imported", "completion_on": now - 86_399},
            {"hash": "failed", "category": "books", "completion_on": now - 200_000},
            {"hash": "incomplete", "category": "imported", "completion_on": 0},
        ]
        self.assertEqual(cleanup.select_cleanup_hashes(torrents, now), ["eligible"])

    def test_delete_payload_requests_file_deletion(self):
        payload = cleanup.delete_payload(["one", "two"], delete_files=True)
        self.assertEqual(payload["hashes"], "one|two")
        self.assertEqual(payload["deleteFiles"], "true")

    def test_empty_selection_never_builds_a_delete_request(self):
        self.assertEqual(cleanup.select_cleanup_hashes([], 200_000), [])


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run tests and verify RED**

```bash
python3 -m unittest scripts/tests/test_qbittorrent_cleanup.py -v
```

Expected: FAIL because `cleanup.py` does not exist.

- [ ] **Step 3: Implement the cleanup module**

Create `cleanup.py` with standard-library HTTP and these exact policy functions:

```python
#!/usr/bin/env python3
import http.cookiejar
import json
import os
import sys
import time
import urllib.parse
import urllib.request

RETENTION_SECONDS = 86_400


def eligible_for_cleanup(torrent, now, retention_seconds=RETENTION_SECONDS):
    completion_on = int(torrent.get("completion_on") or 0)
    return (
        torrent.get("category") == "imported"
        and completion_on > 0
        and now - completion_on >= retention_seconds
    )


def select_cleanup_hashes(torrents, now):
    return [torrent["hash"] for torrent in torrents
            if torrent.get("hash") and eligible_for_cleanup(torrent, now)]


def delete_payload(hashes, delete_files):
    return {"hashes": "|".join(hashes),
            "deleteFiles": "true" if delete_files else "false"}
```

Add `QBittorrentClient` using `HTTPCookieProcessor`. `login()` POSTs to
`/api/v2/auth/login` and requires `Ok.`; `list_torrents()` GETs
`/api/v2/torrents/info?category=imported`; `delete_torrents()` POSTs to
`/api/v2/torrents/delete` using `delete_payload(hashes, True)`.

`main()` reads `QBITTORRENT_URL`, `QBITTORRENT_USERNAME`,
`QBITTORRENT_PASSWORD`, and optional `QBITTORRENT_CLEANUP_DRY_RUN`. It logs only
counts and hashes. It sends no delete request when the selection is empty or
dry-run is true.

- [ ] **Step 4: Verify GREEN**

```bash
python3 -m unittest scripts/tests/test_qbittorrent_cleanup.py -v
python3 -m py_compile apps/base/qbittorrent/scripts/cleanup.py
```

Expected: three tests PASS and syntax check exits 0.

- [ ] **Step 5: Commit**

```bash
git add apps/base/qbittorrent/scripts/cleanup.py scripts/tests/test_qbittorrent_cleanup.py
git commit -m "feat: add safe qBittorrent cleanup policy"
```

---

### Task 2: Implement and Test qBittorrent Configuration Bootstrap

**Files:**
- Create: `apps/base/qbittorrent/scripts/bootstrap.py`
- Create: `scripts/tests/test_qbittorrent_bootstrap.py`

**Interfaces:**
- Consumes: `QBITTORRENT_USERNAME`, `QBITTORRENT_PASSWORD_HASH`, and `/config/qBittorrent/qBittorrent.conf`.
- Produces: `upsert_section_values(text: str, section: str, values: dict[str, str]) -> str` and idempotent Web UI configuration.

- [ ] **Step 1: Write failing bootstrap tests**

Create `scripts/tests/test_qbittorrent_bootstrap.py`:

```python
import importlib.util
from pathlib import Path
import unittest

MODULE_PATH = Path(__file__).parents[2] / "apps/base/qbittorrent/scripts/bootstrap.py"
SPEC = importlib.util.spec_from_file_location("qbittorrent_bootstrap", MODULE_PATH)
bootstrap = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(bootstrap)


class BootstrapTests(unittest.TestCase):
    def test_creates_preferences_and_preserves_unrelated_sections(self):
        original = "[LegalNotice]\nAccepted=true\n"
        rendered = bootstrap.upsert_section_values(
            original, "Preferences",
            {"WebUI\\Username": "admin", "WebUI\\Port": "8080"})
        self.assertIn("[LegalNotice]\nAccepted=true", rendered)
        self.assertIn("[Preferences]", rendered)
        self.assertIn("WebUI\\Username=admin", rendered)

    def test_replaces_critical_value_without_duplication(self):
        original = "[Preferences]\nWebUI\\Username=old\nWebUI\\Port=8080\n"
        rendered = bootstrap.upsert_section_values(
            original, "Preferences", {"WebUI\\Username": "admin"})
        self.assertEqual(rendered.count("WebUI\\Username="), 1)
        self.assertIn("WebUI\\Username=admin", rendered)

    def test_second_render_is_byte_identical(self):
        values = {"WebUI\\Username": "admin", "WebUI\\Port": "8080"}
        first = bootstrap.upsert_section_values("", "Preferences", values)
        self.assertEqual(first, bootstrap.upsert_section_values(first, "Preferences", values))


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run tests and verify RED**

```bash
python3 -m unittest scripts/tests/test_qbittorrent_bootstrap.py -v
```

Expected: FAIL because `bootstrap.py` does not exist.

- [ ] **Step 3: Implement the line-preserving bootstrap**

Implement `upsert_section_values()` as a line-oriented INI updater: locate the
exact section, replace matching keys before the next section, append missing
keys, create the section when absent, and return exactly one trailing newline.

`main()` atomically writes these values with `tempfile.NamedTemporaryFile` and
`os.replace()`:

```python
values = {
    "WebUI\\Address": "*",
    "WebUI\\CSRFProtection": "true",
    "WebUI\\ClickjackingProtection": "true",
    "WebUI\\HostHeaderValidation": "true",
    "WebUI\\LocalHostAuth": "true",
    "WebUI\\Password_PBKDF2": os.environ["QBITTORRENT_PASSWORD_HASH"],
    "WebUI\\Port": "8080",
    "WebUI\\ServerDomains": "torrent.int.harville.dev,qbittorrent,qbittorrent.apps.svc,qbittorrent.apps.svc.cluster.local",
    "WebUI\\UseUPnP": "false",
    "WebUI\\Username": os.environ["QBITTORRENT_USERNAME"],
}
```

Target `${QBITTORRENT_CONFIG_DIR:-/config}/qBittorrent/qBittorrent.conf`.
Create the directory mode `0750` and file mode `0600`. Never log secret values.

- [ ] **Step 4: Verify GREEN**

```bash
python3 -m unittest scripts/tests/test_qbittorrent_bootstrap.py -v
python3 -m py_compile apps/base/qbittorrent/scripts/bootstrap.py
```

Expected: three tests PASS and syntax check exits 0.

- [ ] **Step 5: Commit**

```bash
git add apps/base/qbittorrent/scripts/bootstrap.py scripts/tests/test_qbittorrent_bootstrap.py
git commit -m "feat: add qBittorrent config bootstrap"
```

---

### Task 3: Add the qBittorrent/Gluetun Kubernetes Base

**Files:**
- Create: `apps/base/qbittorrent/{kustomization,deployment,pvcs,services,ingress,cleanup-cronjob}.yaml`
- Create: `scripts/validate_qbittorrent_manifests.rb`
- Modify: `clusters/homelab/apps/kustomization.yaml`

**Interfaces:**
- Consumes: Secret `qbittorrent`, generated scripts ConfigMap, Longhorn, internal Traefik.
- Produces: `qbittorrent.apps.svc:8080`, PVC `qbittorrent-downloads`, and `torrent.int.harville.dev`.

- [ ] Write a rendered-manifest validator asserting: Gluetun is a native sidecar with only `NET_ADMIN`; `/dev/net/tun` exists only there; qBittorrent is unprivileged; DL380 is excluded; downloads are 50Gi RWX; Ingress host/class/middleware are exact; cleanup schedule is `15 6 * * *`.
- [ ] Run `ruby scripts/validate_qbittorrent_manifests.rb` and verify failure because the Deployment is absent.
- [ ] Add the base with Gluetun `ghcr.io/qdm12/gluetun:v3.41.1`, LinuxServer qBittorrent `5.2.0_v2.0.12-ls454`, bootstrap init container, 2Gi retained config PVC, 50Gi RWX downloads PVC, Service, Ingress, and daily cleanup CronJob.
- [ ] Generate the scripts ConfigMap from `scripts/bootstrap.py` and `scripts/cleanup.py`; keep Kustomize's name suffix hash enabled so script changes roll consumers.
- [ ] Register `../../../apps/base/qbittorrent`, then run `kubectl kustomize apps/base/qbittorrent >/dev/null` and the validator until both pass.
- [ ] Commit with `git commit -m "feat: add qBittorrent NordVPN workload"`.

### Task 4: Add Encrypted Credentials and Shelfmark Wiring

**Files:**
- Create: `clusters/homelab/apps/secrets/qbittorrent.yaml`
- Modify: `clusters/homelab/apps/kustomization.yaml`
- Modify: `apps/base/books/deployment.yaml`
- Modify: `scripts/validate_qbittorrent_manifests.rb`

**Interfaces:**
- Produces Secret keys `NORDVPN_SERVICE_USERNAME`, `NORDVPN_SERVICE_PASSWORD`, `QBITTORRENT_USERNAME`, `QBITTORRENT_PASSWORD`, and `QBITTORRENT_PASSWORD_HASH`.

- [ ] Extend the validator for Shelfmark's internal URL, secret refs, `/data/torrents` mount, categories `books`/`imported`, and 24-hour cleanup; run it and verify RED.
- [ ] Generate a 48-hex-character qBittorrent password and a 16-byte-salt PBKDF2-HMAC-SHA512 verifier with 100,000 iterations in qBittorrent `@ByteArray(BASE64_SALT:BASE64_HASH)` format.
- [ ] Create the Secret with the supplied NordVPN credentials and generated qBittorrent values, immediately run `sops --encrypt --in-place`, and verify `sops filestatus` reports encrypted.
- [ ] Add the Secret resource and SOPS-MAC replacements that roll both qBittorrent and Books.
- [ ] Add Shelfmark qBittorrent env, secret refs, categories, internal URL, and shared RWX mount.
- [ ] Run the validator, app render, and `git diff --check`; commit with `git commit -m "feat: connect Shelfmark to qBittorrent"`.

### Task 5: Add Authentik, Pod Security, and Image Automation

**Files:**
- Modify: `apps/base/authentik/blueprint.yaml`
- Modify: `infrastructure/base/namespaces/namespaces.yaml`
- Modify: `infrastructure/base/flux-image-automation/books.yaml`
- Modify: `scripts/validate_qbittorrent_manifests.rb`

- [ ] Extend the validator for privileged `apps` namespace labels, qBittorrent image resources, Authentik provider/application/admin binding/outpost registration, and absence of a new group; verify RED.
- [ ] Label only Namespace `apps` enforce/audit/warn `privileged` so Pod Security admits Gluetun.
- [ ] Add the qBittorrent ImageRepository and a numerical policy restricted to stable `5.2.x` LinuxServer tags; add its Flux setter comment. Keep Gluetun manually pinned.
- [ ] Add Authentik proxy provider `qbittorrent-provider`, application slug `qbittorrent`, `authentik Admins` binding, and embedded-outpost provider entry. Create no group.
- [ ] Run validator plus apps/infra/image-automation renders; commit with `git commit -m "feat: secure qBittorrent access and updates"`.

### Task 6: Verify the Repository

- [ ] Run both Python test modules; expected six passing tests.
- [ ] Run the Ruby manifest validator.
- [ ] Render apps, infra, flux-system, and image-automation.
- [ ] Run `uvx pre-commit run --all-files`.
- [ ] Verify the Secret is encrypted and privilege references are Gluetun-only.

### Task 7: Push, Reconcile, and Verify Live

- [ ] Push `main`, reconcile Flux root, infra, image-automation, and apps in dependency order.
- [ ] Verify Books and qBittorrent rollouts, PVC binding, and non-DL380 scheduling.
- [ ] Run Gluetun healthcheck and verify NordVPN/United States/OpenVPN with VPN egress different from normal homelab egress.
- [ ] Verify `torrent.int.harville.dev` redirects to Authentik and qBittorrent API authentication succeeds from Shelfmark without printing credentials.
- [ ] Verify cleanup CronJob schedule and report any public-domain end-to-end download check that remains pending because Shelfmark has no configured source.
