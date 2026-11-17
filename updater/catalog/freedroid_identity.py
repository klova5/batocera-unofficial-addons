#!/usr/bin/env python3

import hashlib
import re
import subprocess
import urllib.request

PAGE = "https://freedroid.org/download/"

req = urllib.request.Request(
    PAGE,
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

m = re.search(
    r'freedroidRPG-([0-9]+(?:\.[0-9]+)+)',
    html,
    re.I,
)

if not m:
    raise SystemExit(
        "Unable to determine current FreedroidRPG version"
    )

version = m.group(1)

asset = f"freedroidRPG-{version}-x86_64.AppImage"

url = (
    "https://ftp.osuosl.org/pub/freedroid/"
    f"freedroidRPG-{version}/{asset}"
)

result = subprocess.run(
    ["curl", "-fsSIL", url],
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
    timeout=30,
)

if result.returncode != 0:
    raise SystemExit(
        "Unable to inspect FreedroidRPG AppImage"
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
    "freedroid:"
    + version
    + ":"
    + asset
    + ":"
    + digest
)
