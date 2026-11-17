#!/usr/bin/env python3

import hashlib
import subprocess
import json

URL = "https://ps3i.8101987.xyz/ps3i.tar.xz"

result = subprocess.run(
    ["curl", "-fsSIL", URL],
    stdout=subprocess.PIPE,
    stderr=subprocess.PIPE,
    text=True,
    timeout=30,
)

if result.returncode != 0:
    raise SystemExit(
        "Unable to inspect ps3i tarball"
    )

etag = ""
modified = ""
length = ""

for line in result.stdout.splitlines():
    lower = line.lower()

    if lower.startswith("etag:"):
        etag = line.split(":", 1)[1].strip()
    elif lower.startswith("last-modified:"):
        modified = line.split(":", 1)[1].strip()
    elif lower.startswith("content-length:"):
        length = line.split(":", 1)[1].strip()

payload = {
    "url": URL,
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

print("rolling")
print(
    "ps3i-web:" + digest
)

print(
    json.dumps(
        payload,
        indent=2,
    )
)
