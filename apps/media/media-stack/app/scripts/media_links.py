#!/usr/bin/env python3
"""Enforce how the media apps reach each other, through their own APIs.

Radarr and Prowlarr keep download clients, indexers and the Prowlarr -> Radarr
link in their databases, where Git can't see them; a namespace move once left
every one of them pointing at addresses that no longer existed. This runs on a
schedule and puts them back. It only creates or corrects what is declared
below and never deletes anything added by hand.
"""

import json
import os
import sys
import time
import urllib.error
import urllib.request

RADARR = "http://radarr:7878/api/v3"
PROWLARR = "http://prowlarr:9696/api/v1"

QBITTORRENT = {"host": "qbittorrent", "port": 8080, "useSsl": False, "urlBase": ""}
MOVIE_ROOT = "/media/library/movies"
# Prowlarr indexer definitions to keep enabled. YTS is movie-only and has no
# Cloudflare front, so it keeps Radarr searching when The Pirate Bay is down.
INDEXERS = ["thepiratebay", "yts", "limetorrents"]


def call(base, key, method, path, body=None):
    request = urllib.request.Request(
        base + path,
        method=method,
        data=None if body is None else json.dumps(body).encode(),
        headers={"X-Api-Key": key, "Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            raw = response.read()
    except urllib.error.HTTPError as error:
        detail = error.read().decode(errors="replace")[:500]
        raise SystemExit(f"{method} {base}{path}: HTTP {error.code}: {detail}")
    return json.loads(raw) if raw else None


def wait_until_up(base, key, name):
    for _ in range(30):
        try:
            call(base, key, "GET", "/system/status")
            return
        except (SystemExit, OSError):
            time.sleep(10)
    raise SystemExit(f"{name} did not answer within 5 minutes")


def masked(value):
    return isinstance(value, str) and value.startswith("****")


def apply_fields(resource, desired):
    """Set named fields; report whether anything changed.

    The APIs return secrets (API keys, passwords) masked, so those can't be
    compared; they are written on create and left alone after that.
    """
    changed = False
    for field in resource["fields"]:
        if masked(field.get("value")):
            continue
        if field["name"] in desired and field.get("value") != desired[field["name"]]:
            field["value"] = desired[field["name"]]
            changed = True
    return changed


def ensure(base, key, kind, implementation, name, fields, create_only=None, extra=None):
    """Create `kind` from its schema, or correct an existing one in place."""
    existing = [r for r in call(base, key, "GET", f"/{kind}") if r["implementation"] == implementation]
    if existing:
        resource = existing[0]
        changed = apply_fields(resource, fields)
        for attribute, value in (extra or {}).items():
            if resource.get(attribute) != value:
                resource[attribute] = value
                changed = True
        if changed:
            call(base, key, "PUT", f"/{kind}/{resource['id']}", resource)
            print(f"{kind} {resource['name']}: corrected")
        else:
            print(f"{kind} {resource['name']}: ok")
        return
    schema = next(s for s in call(base, key, "GET", f"/{kind}/schema") if s["implementation"] == implementation)
    apply_fields(schema, {**fields, **(create_only or {})})
    schema.update({"name": name, "enable": True, **(extra or {})})
    call(base, key, "POST", f"/{kind}", schema)
    print(f"{kind} {name}: created")


def main():
    radarr_key = os.environ["RADARR_API_KEY"]
    prowlarr_key = os.environ["PROWLARR_API_KEY"]
    # Pods in the cluster network skip qBittorrent's login (AuthSubnetWhitelist);
    # the credentials only matter if that whitelist ever goes away.
    credentials = {
        "username": os.environ["QBITTORRENT_USERNAME"],
        "password": os.environ["QBITTORRENT_PASSWORD"],
    }

    wait_until_up(RADARR, radarr_key, "Radarr")
    wait_until_up(PROWLARR, prowlarr_key, "Prowlarr")

    # Radarr: where movies go, and which client downloads them.
    roots = [r["path"] for r in call(RADARR, radarr_key, "GET", "/rootfolder")]
    if MOVIE_ROOT not in roots:
        call(RADARR, radarr_key, "POST", "/rootfolder", {"path": MOVIE_ROOT})
        print(f"rootfolder {MOVIE_ROOT}: created")
    ensure(RADARR, radarr_key, "downloadclient", "QBittorrent", "qBittorrent",
           {**QBITTORRENT, "movieCategory": "movies"}, credentials)
    # Tell Jellyfin to rescan as soon as a movie is imported, renamed or
    # removed, instead of waiting for its 12-hourly library scan.
    ensure(RADARR, radarr_key, "notification", "MediaBrowser", "Jellyfin",
           {"host": "jellyfin", "port": 8096, "useSsl": False, "updateLibrary": True, "notify": False},
           {"apiKey": os.environ["JELLYFIN_API_KEY"]},
           extra={"onDownload": True, "onUpgrade": True, "onRename": True,
                  "onMovieDelete": True, "onMovieFileDelete": True,
                  "onMovieFileDeleteForUpgrade": True})

    # Prowlarr: its own client, the link that pushes indexers into Radarr,
    # and the indexers themselves.
    ensure(PROWLARR, prowlarr_key, "downloadclient", "QBittorrent", "qBittorrent",
           {**QBITTORRENT, "category": "prowlarr"}, credentials)
    ensure(PROWLARR, prowlarr_key, "applications", "Radarr", "Radarr",
           {"prowlarrUrl": "http://prowlarr:9696", "baseUrl": "http://radarr:7878"},
           {"apiKey": radarr_key}, extra={"syncLevel": "fullSync"})
    # The stored Radarr key is masked, so test the link instead: if Radarr
    # rejects it (the key was rotated), send the current one.
    for app in call(PROWLARR, prowlarr_key, "GET", "/applications"):
        if app["implementation"] != "Radarr":
            continue
        try:
            call(PROWLARR, prowlarr_key, "POST", "/applications/test", app)
        except SystemExit:
            for field in app["fields"]:
                if field["name"] == "apiKey":
                    field["value"] = radarr_key
            call(PROWLARR, prowlarr_key, "PUT", f"/applications/{app['id']}", app)
            print("applications Radarr: API key refreshed")

    have = {i["definitionName"]: i for i in call(PROWLARR, prowlarr_key, "GET", "/indexer")}
    schemas = None
    for definition in INDEXERS:
        indexer = have.get(definition)
        if indexer is None:
            schemas = schemas or call(PROWLARR, prowlarr_key, "GET", "/indexer/schema")
            indexer = next(s for s in schemas if s["definitionName"] == definition)
            indexer.update({"enable": True, "appProfileId": 1, "priority": 25})
            call(PROWLARR, prowlarr_key, "POST", "/indexer", indexer)
            print(f"indexer {indexer['name']}: created")
        elif not indexer["enable"]:
            indexer["enable"] = True
            call(PROWLARR, prowlarr_key, "PUT", f"/indexer/{indexer['id']}", indexer)
            print(f"indexer {indexer['name']}: re-enabled")
        else:
            print(f"indexer {indexer['name']}: ok")

    call(PROWLARR, prowlarr_key, "POST", "/command", {"name": "ApplicationIndexerSync"})
    print("indexer sync to Radarr: queued")


if __name__ == "__main__":
    sys.exit(main())
