#!/usr/bin/env python3
import os
from pathlib import Path
import tempfile


def upsert_section_values(text, section, values):
    lines = text.splitlines()
    header = f"[{section}]"

    try:
        section_start = lines.index(header)
    except ValueError:
        if lines and lines[-1] != "":
            lines.append("")
        lines.append(header)
        section_start = len(lines) - 1

    section_end = len(lines)
    for index in range(section_start + 1, len(lines)):
        line = lines[index]
        if line.startswith("[") and line.endswith("]"):
            section_end = index
            break

    remaining = dict(values)
    for index in range(section_start + 1, section_end):
        key, separator, _ = lines[index].partition("=")
        if separator and key in remaining:
            lines[index] = f"{key}={remaining.pop(key)}"

    if remaining:
        additions = [f"{key}={value}" for key, value in remaining.items()]
        lines[section_end:section_end] = additions

    return "\n".join(lines).rstrip("\n") + "\n"


def preference_values(username, password_hash):
    return {
        "WebUI\\Address": "*",
        "WebUI\\AuthSubnetWhitelist": "10.244.0.0/16",
        "WebUI\\AuthSubnetWhitelistEnabled": "true",
        "WebUI\\CSRFProtection": "true",
        "WebUI\\ClickjackingProtection": "true",
        "WebUI\\HostHeaderValidation": "true",
        "WebUI\\LocalHostAuth": "true",
        "WebUI\\Password_PBKDF2": password_hash,
        "WebUI\\Port": "8080",
        "WebUI\\ServerDomains": (
            '"torrent.int.harville.dev;qbittorrent;qbittorrent.apps.svc;'
            'qbittorrent.apps.svc.cluster.local"'
        ),
        "WebUI\\UseUPnP": "false",
        "WebUI\\Username": username,
    }


def main():
    config_root = Path(os.environ.get("QBITTORRENT_CONFIG_DIR", "/config"))
    config_dir = config_root / "qBittorrent"
    config_path = config_dir / "qBittorrent.conf"
    config_dir.mkdir(parents=True, exist_ok=True, mode=0o750)

    current = config_path.read_text() if config_path.exists() else ""
    values = preference_values(
        os.environ["QBITTORRENT_USERNAME"],
        os.environ["QBITTORRENT_PASSWORD_HASH"],
    )
    rendered = upsert_section_values(current, "Preferences", values)

    with tempfile.NamedTemporaryFile(
        mode="w",
        dir=config_dir,
        prefix="qBittorrent.conf.",
        delete=False,
    ) as temporary:
        temporary.write(rendered)
        temporary_path = Path(temporary.name)
    temporary_path.chmod(0o600)
    os.replace(temporary_path, config_path)


if __name__ == "__main__":
    main()
