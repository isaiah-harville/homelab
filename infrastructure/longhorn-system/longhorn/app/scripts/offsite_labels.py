#!/usr/bin/env python3
"""Copy recurring-job-group labels from PVCs onto their Longhorn volumes.

Which recurring jobs run against a volume is a label on the Longhorn Volume,
and Longhorn never copies it from the PVC. Without this, a volume marked in
Git for weekly off-site backups would quietly never be backed up.
"""

import json
import ssl
import urllib.request

PREFIX = "recurring-job-group.longhorn.io/"
ROOT = "https://kubernetes.default.svc"
SA = "/var/run/secrets/kubernetes.io/serviceaccount"

with open(f"{SA}/token") as handle:
    TOKEN = handle.read().strip()
CONTEXT = ssl.create_default_context(cafile=f"{SA}/ca.crt")


def call(method, path, body=None, content_type="application/json"):
    request = urllib.request.Request(
        ROOT + path,
        method=method,
        data=None if body is None else json.dumps(body).encode(),
        headers={"Authorization": f"Bearer {TOKEN}", "Accept": "application/json",
                 **({"Content-Type": content_type} if body is not None else {})},
    )
    with urllib.request.urlopen(request, timeout=60, context=CONTEXT) as response:
        return json.loads(response.read())


def main():
    volumes = {
        volume["metadata"]["name"]: volume["metadata"].get("labels") or {}
        for volume in call("GET", "/apis/longhorn.io/v1beta2/namespaces/longhorn-system/volumes")["items"]
    }
    changed = 0
    for claim in call("GET", "/api/v1/persistentvolumeclaims")["items"]:
        volume_name = claim["spec"].get("volumeName")
        wanted = {key: value for key, value in (claim["metadata"].get("labels") or {}).items()
                  if key.startswith(PREFIX)}
        if not volume_name or not wanted or volume_name not in volumes:
            continue
        missing = {key: value for key, value in wanted.items() if volumes[volume_name].get(key) != value}
        if not missing:
            continue
        call("PATCH",
             f"/apis/longhorn.io/v1beta2/namespaces/longhorn-system/volumes/{volume_name}",
             {"metadata": {"labels": missing}},
             "application/merge-patch+json")
        print(f"{claim['metadata']['namespace']}/{claim['metadata']['name']} -> {volume_name}: "
              + ", ".join(sorted(missing)))
        changed += 1
    print(f"volumes updated: {changed}")


if __name__ == "__main__":
    main()
