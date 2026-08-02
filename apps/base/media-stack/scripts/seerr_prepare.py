#!/usr/bin/env python3
"""Keep Seerr's native Authentik OIDC provider declarative and idempotent."""

import json
import os
from pathlib import Path
import sqlite3


REQUEST_PERMISSION = 32
AUTO_APPROVE_PERMISSION = 128
ADMIN_PERMISSION = 2

config_directory = Path(os.environ.get("CONFIG_DIRECTORY", "/app/config"))
settings_path = config_directory / "settings.json"
try:
    settings = json.loads(settings_path.read_text())
except FileNotFoundError:
    settings = {}

main = settings.setdefault("main", {})
# The preview's pre-migration probe loads settings without merging defaults.
# Mark a new installation explicitly so it does not mistake an empty database
# for an Overseerr database before TypeORM has created its migration table.
main.setdefault("mediaServerType", 4)
main.update(
    {
        "applicationUrl": "https://movies.harville.dev",
        "localLogin": False,
        "mediaServerLogin": False,
        "oidcLogin": True,
        "defaultPermissions": REQUEST_PERMISSION | AUTO_APPROVE_PERMISSION,
    }
)
settings["oidc"] = {
    "providers": [
        {
            "slug": "authentik",
            "name": "Authentik",
            "issuerUrl": "https://auth.harville.dev/application/o/seerr/",
            "clientId": os.environ["SEERR_OIDC_CLIENT_ID"],
            "clientSecret": os.environ["SEERR_OIDC_CLIENT_SECRET"],
            "logo": "https://cdn.jsdelivr.net/gh/selfhst/icons/svg/authentik.svg",
            "scopes": "openid profile email",
            "newUserLogin": True,
        }
    ]
}

database_path = config_directory / "db/db.sqlite3"
if database_path.exists():
    with sqlite3.connect(database_path) as database:
        user_table_exists = database.execute(
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'user'"
        ).fetchone()
        if user_table_exists:
            database.execute(
                'UPDATE "user" '
                "SET permissions = permissions | ? "
                "WHERE (permissions & ?) = 0",
                (AUTO_APPROVE_PERMISSION, ADMIN_PERMISSION),
            )

temporary_path = settings_path.with_suffix(".json.tmp")
temporary_path.write_text(json.dumps(settings, indent=2) + "\n")
temporary_path.replace(settings_path)
settings_path.chmod(0o600)
