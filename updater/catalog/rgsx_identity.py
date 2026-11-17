#!/usr/bin/env python3

import hashlib
import json
import re
import subprocess


LATEST_URL = (
    "https://github.com/RetroGameSets/RGSX/"
    "releases/latest/download/RGSX_Full_latest.zip"
)

result = subprocess.run(
    ["curl", "-fsSIL", LATEST_URL],
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
    timeout=45,
)

if result.returncode != 0:
    raise SystemExit(
        "Unable to inspect RGSX latest asset"
    )

tag = ""
etag = ""
modified = ""
length = ""

for line in result.stdout.splitlines():
    low = line.lower()

    if low.startswith("location:"):
        location = line.split(":", 1)[1].strip()

        m = re.search(
            r"/releases/download/([^/]+)/RGSX_Full_latest\.zip",
            location,
            re.I,
        )

        if m:
            tag = m.group(1)

    elif low.startswith("etag:"):
        etag = line.split(":", 1)[1].strip()

    elif low.startswith("last-modified:"):
        modified = line.split(":", 1)[1].strip()

    elif low.startswith("content-length:"):
        value = line.split(":", 1)[1].strip()

        if value and value != "0":
            length = value


if not tag:
    raise SystemExit(
        "Unable to determine RGSX release tag"
    )

payload = {
    "tag": tag,
    "asset": "RGSX_Full_latest.zip",
    "etag": etag,
    "last_modified": modified,
    "content_length": length,
}

digest = hashlib.sha256(
    json.dumps(
        payload,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
).hexdigest()


print(tag)

print(
    "rgsx:"
    + tag
    + ":RGSX_Full_latest.zip:"
    + digest
)
