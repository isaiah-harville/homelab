#!/usr/bin/env python3
"""Keep Seerr's native Authentik OIDC provider declarative and idempotent."""

import json
import os
from pathlib import Path


settings_path = Path("/app/config/settings.json")
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

temporary_path = settings_path.with_suffix(".json.tmp")
temporary_path.write_text(json.dumps(settings, indent=2) + "\n")
temporary_path.replace(settings_path)
settings_path.chmod(0o600)
