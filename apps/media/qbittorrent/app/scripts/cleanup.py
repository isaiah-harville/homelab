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
    return [
        torrent["hash"]
        for torrent in torrents
        if torrent.get("hash") and eligible_for_cleanup(torrent, now)
    ]


def delete_payload(hashes, delete_files):
    return {
        "hashes": "|".join(hashes),
        "deleteFiles": "true" if delete_files else "false",
    }


class QBittorrentClient:
    def __init__(self, base_url, username, password, timeout=30):
        self.base_url = base_url.rstrip("/")
        self.username = username
        self.password = password
        self.timeout = timeout
        cookie_jar = http.cookiejar.CookieJar()
        self.opener = urllib.request.build_opener(
            urllib.request.HTTPCookieProcessor(cookie_jar)
        )

    def _url(self, path):
        return f"{self.base_url}{path}"

    def _post(self, path, payload):
        data = urllib.parse.urlencode(payload).encode()
        request = urllib.request.Request(self._url(path), data=data, method="POST")
        with self.opener.open(request, timeout=self.timeout) as response:
            return response.read().decode()

    def login(self):
        response = self._post(
            "/api/v2/auth/login",
            {"username": self.username, "password": self.password},
        )
        if response.strip() not in {"", "Ok."}:
            raise RuntimeError("qBittorrent authentication failed")

    def list_torrents(self, category):
        query = urllib.parse.urlencode({"category": category})
        request = urllib.request.Request(
            self._url(f"/api/v2/torrents/info?{query}"), method="GET"
        )
        with self.opener.open(request, timeout=self.timeout) as response:
            return json.load(response)

    def delete_torrents(self, hashes, delete_files=True):
        if not hashes:
            return
        self._post(
            "/api/v2/torrents/delete",
            delete_payload(hashes, delete_files),
        )


def _enabled(value):
    return value.lower() in {"1", "true", "yes", "on"}


def main():
    client = QBittorrentClient(
        os.environ["QBITTORRENT_URL"],
        os.environ["QBITTORRENT_USERNAME"],
        os.environ["QBITTORRENT_PASSWORD"],
    )
    client.login()
    hashes = select_cleanup_hashes(client.list_torrents("imported"), int(time.time()))
    if not hashes:
        print("No imported torrents are eligible for cleanup")
        return 0

    dry_run = _enabled(os.environ.get("QBITTORRENT_CLEANUP_DRY_RUN", "false"))
    print(f"Selected {len(hashes)} imported torrent(s): {','.join(hashes)}")
    if dry_run:
        print("Dry run enabled; no torrent data deleted")
        return 0

    client.delete_torrents(hashes, delete_files=True)
    print(f"Deleted {len(hashes)} imported torrent(s) and their data")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:
        print(f"qBittorrent cleanup failed: {exc}", file=sys.stderr)
        sys.exit(1)
