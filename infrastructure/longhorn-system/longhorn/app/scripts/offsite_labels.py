#!/usr/bin/env python3
"""Copy recurring-job-group labels from PVCs onto their Longhorn volumes.

Which recurring jobs run against a volume is a label on the Longhorn Volume,
and Longhorn never copies it from the PVC. Without this, a volume marked in
Git for weekly off-site backups would quietly never be backed up.

Longhorn puts every volume it creates in the `default` group, and a group
label on the PVC doesn't take it out again. So when a PVC names its groups
and leaves `default` out (Prometheus and Loki use only `rolling`, which
never snapshots), the volume's `default` label is removed. PVCs that want
the default snapshots alongside another group list `default` themselves.
"""

import json
import ssl
import urllib.request

PREFIX = "recurring-job-group.longhorn.io/"
DEFAULT = PREFIX + "default"
ROOT = "https://kubernetes.default.svc"
SA = "/var/run/secrets/kubernetes.io/serviceaccount"


def label_patch(claim_labels, volume_labels):
    """Labels to merge-patch onto the volume; None removes one."""
    wanted = {key: value for key, value in (claim_labels or {}).items() if key.startswith(PREFIX)}
    if not wanted:
        return {}
    current = volume_labels or {}
    patch = {key: value for key, value in wanted.items() if current.get(key) != value}
    if DEFAULT not in wanted and DEFAULT in current:
        patch[DEFAULT] = None
    return patch


def client():
    with open(f"{SA}/token") as handle:
        token = handle.read().strip()
    context = ssl.create_default_context(cafile=f"{SA}/ca.crt")

    def call(method, path, body=None, content_type="application/json"):
        request = urllib.request.Request(
            ROOT + path,
            method=method,
            data=None if body is None else json.dumps(body).encode(),
            headers={"Authorization": f"Bearer {token}", "Accept": "application/json",
                     **({"Content-Type": content_type} if body is not None else {})},
        )
        with urllib.request.urlopen(request, timeout=60, context=context) as response:
            return json.loads(response.read())

    return call


def main():
    call = client()
    volumes = {
        volume["metadata"]["name"]: volume["metadata"].get("labels") or {}
        for volume in call("GET", "/apis/longhorn.io/v1beta2/namespaces/longhorn-system/volumes")["items"]
    }
    changed = 0
    for claim in call("GET", "/api/v1/persistentvolumeclaims")["items"]:
        volume_name = claim["spec"].get("volumeName")
        if not volume_name or volume_name not in volumes:
            continue
        patch = label_patch(claim["metadata"].get("labels"), volumes[volume_name])
        if not patch:
            continue
        call("PATCH",
             f"/apis/longhorn.io/v1beta2/namespaces/longhorn-system/volumes/{volume_name}",
             {"metadata": {"labels": patch}},
             "application/merge-patch+json")
        print(f"{claim['metadata']['namespace']}/{claim['metadata']['name']} -> {volume_name}: "
              + ", ".join(f"-{key}" if value is None else key for key, value in sorted(patch.items())))
        changed += 1
    print(f"volumes updated: {changed}")


if __name__ == "__main__":
    main()
