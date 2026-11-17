#!/usr/bin/env python3

import hashlib
import re
import subprocess
import urllib.request

INDEX = "https://dl.xonotic.org/"

req = urllib.request.Request(
    INDEX,
    headers={
        "User-Agent": "BUA-Updater",
        "Cache-Control": "no-cache",
    },
)

with urllib.request.urlopen(
    req,
    timeout=30,
) as response:
    html = response.read().decode(
        "utf-8",
        errors="replace",
    )

versions = []

for m in re.finditer(
    r'xonotic-([0-9]+\.[0-9]+\.[0-9]+)\.zip',
    html,
    re.I,
):
    versions.append(
        tuple(
            int(x)
            for x in m.group(1).split(".")
        )
    )

if not versions:
    raise SystemExit(
        "Unable to determine latest Xonotic release"
    )

latest = max(versions)

version = ".".join(
    str(x)
    for x in latest
)

asset = f"xonotic-{version}.zip"

url = INDEX + asset

result = subprocess.run(
    ["curl", "-fsSIL", url],
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
    timeout=30,
)

if result.returncode != 0:
    raise SystemExit(
        "Unable to inspect Xonotic release archive"
    )

etag = ""
modified = ""
length = ""

for line in result.stdout.splitlines():
    low = line.lower()

    if low.startswith("etag:"):
        etag = line.split(":", 1)[1].strip()
    elif low.startswith("last-modified:"):
        modified = line.split(":", 1)[1].strip()
    elif low.startswith("content-length:"):
        length = line.split(":", 1)[1].strip()

payload = "\n".join(
    [
        version,
        asset,
        url,
        etag,
        modified,
        length,
    ]
).encode("utf-8")

digest = hashlib.sha256(
    payload
).hexdigest()

print(version)

print(
    "xonotic:"
    + version
    + ":"
    + asset
    + ":"
    + digest
)
