"""Apply Git-managed mail and Kindle settings to Calibre-Web-Automated.

CWA keeps its SMTP settings and each user's eReader address in /config/app.db
and cannot read them from the environment. This runs as an initContainer before
CWA starts, so the values in Git (and the SOPS secrets) win on every restart.

Kindle delivery is per user. Shelfmark writes each download to /books/<user>/,
which is /cwa-book-ingest/<user>/ here, and CWA only auto-sends a book from that
folder to the CWA user with the same name. Every entry in the recipients file
becomes (or updates) a CWA user with auto-send on. Users missing from the file
lose their eReader address, so Git is the only place to change them.
"""

import json
import os
import secrets
import sqlite3
import sys
from base64 import urlsafe_b64decode
from pathlib import Path

from cryptography.fernet import Fernet
from werkzeug.security import generate_password_hash

CONFIG_DIR = Path(os.environ.get("CWA_CONFIG_DIR", "/config"))
APP_DB = CONFIG_DIR / "app.db"
KEY_FILE = CONFIG_DIR / ".key"
RECIPIENTS_FILE = Path(os.environ["KINDLE_RECIPIENTS_FILE"])
SMTP_PASSWORD_FILE = Path(os.environ["SMTP_PASSWORD_FILE"])

# CWA's mail_use_ssl values: 0 none, 1 STARTTLS, 2 SSL/TLS.
SSL_MODES = {"none": 0, "starttls": 1, "ssl": 2}


def log(message: str) -> None:
    print(f"[cwa-config] {message}", flush=True)


def encryption_key() -> bytes:
    """Read CWA's Fernet key, creating it the way CWA does if it is missing."""
    if KEY_FILE.exists() and KEY_FILE.stat().st_size > 32:
        key = KEY_FILE.read_bytes()
        try:
            urlsafe_b64decode(key)
            return key
        except ValueError:
            pass
    key = Fernet.generate_key()
    KEY_FILE.write_bytes(key)
    log("created a new CWA encryption key")
    return key


def load_recipients() -> dict[str, str]:
    """Map lowercase username to a comma-separated list of eReader addresses."""
    raw = json.loads(RECIPIENTS_FILE.read_text() or "{}")
    if not isinstance(raw, dict):
        sys.exit("[cwa-config] recipients must be a JSON object of user -> address(es)")
    recipients = {}
    for user, addresses in raw.items():
        if isinstance(addresses, str):
            addresses = [addresses]
        cleaned = [a.strip() for a in addresses if a and a.strip()]
        if not cleaned or not all("@" in a for a in cleaned):
            sys.exit(f"[cwa-config] recipient {user!r} needs at least one email address")
        recipients[user.strip().lower()] = ",".join(cleaned)
    return recipients


def apply_mail_settings(db: sqlite3.Connection) -> None:
    password = SMTP_PASSWORD_FILE.read_text().strip()
    encrypted = Fernet(encryption_key()).encrypt(password.encode()).decode()
    ssl_mode = SSL_MODES[os.environ.get("SMTP_SECURITY", "ssl").lower()]
    db.execute(
        """
        UPDATE settings SET
            mail_server = ?, mail_port = ?, mail_use_ssl = ?, mail_login = ?,
            mail_password_e = ?, mail_password = '', mail_from = ?, mail_size = ?,
            mail_server_type = 0
        """,
        (
            os.environ["SMTP_HOST"],
            int(os.environ["SMTP_PORT"]),
            ssl_mode,
            os.environ["SMTP_USERNAME"],
            encrypted,
            os.environ["SMTP_FROM"],
            int(os.environ["SMTP_MAX_ATTACHMENT_BYTES"]),
        ),
    )
    log(f"mail server set to {os.environ['SMTP_HOST']}:{os.environ['SMTP_PORT']}")


def apply_recipients(db: sqlite3.Connection, recipients: dict[str, str]) -> None:
    users = {name.lower(): user_id for user_id, name in db.execute("SELECT id, name FROM user")}

    for name, addresses in recipients.items():
        if name in users:
            db.execute(
                "UPDATE user SET kindle_mail = ?, auto_send_enabled = 1 WHERE id = ?",
                (addresses, users[name]),
            )
            log(f"auto-send on for existing user {name}")
            continue
        # A delivery-only account: nobody knows its password, and it has no
        # roles, so it exists only so CWA has a name to route auto-send to.
        db.execute(
            """
            INSERT INTO user (
                name, role, password, kindle_mail, locale, sidebar_view,
                default_language, denied_tags, allowed_tags, denied_column_value,
                allowed_column_value, view_settings, kobo_only_shelves_sync,
                auto_send_enabled, allow_additional_ereader_emails, kindle_mail_subject
            ) VALUES (?, 0, ?, ?, 'en', 1, 'all', '', '', '', '', '{}', 0, 1, 1, '')
            """,
            (name, generate_password_hash(secrets.token_urlsafe(32)), addresses),
        )
        log(f"created delivery user {name} with auto-send on")

    for name, user_id in users.items():
        if name not in recipients:
            db.execute(
                "UPDATE user SET kindle_mail = '', auto_send_enabled = 0 "
                "WHERE id = ? AND (auto_send_enabled = 1 OR kindle_mail != '')",
                (user_id,),
            )


def main() -> None:
    if not APP_DB.exists():
        # CWA creates app.db on its first start; the next restart configures it.
        log(f"{APP_DB} does not exist yet; skipping until CWA has initialised it")
        return
    recipients = load_recipients()
    with sqlite3.connect(APP_DB, timeout=30) as db:
        apply_mail_settings(db)
        apply_recipients(db, recipients)
    log(f"{len(recipients)} Kindle recipient(s) configured")


if __name__ == "__main__":
    main()
