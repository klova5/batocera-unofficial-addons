#!/usr/bin/env python3

import hashlib
import subprocess
import sys

URL = (
    "https://web.fightcade.com/download/"
    "Fightcade-linux-latest.tar.gz"
)

headers = subprocess.check_output(
    [
        "curl",
        "-fsSIL",
        URL,
    ],
    text=True,
)

etag = ""
last_modified = ""
content_length = ""

for line in headers.splitlines():
    lower = line.lower()

    if lower.startswith("etag:"):
        etag = line.split(":", 1)[1].strip()

    elif lower.startswith("last-modified:"):
        last_modified = (
            line.split(":", 1)[1].strip()
        )

    elif lower.startswith("content-length:"):
        content_length = (
            line.split(":", 1)[1].strip()
        )

if not any(
    (
        etag,
        last_modified,
        content_length,
    )
):
    raise SystemExit(
        "Unable to determine Fightcade artifact identity"
    )

fingerprint_source = "\n".join(
    [
        etag,
        last_modified,
        content_length,
    ]
).encode("utf-8")

digest = hashlib.sha256(
    fingerprint_source
).hexdigest()

identity = (
    "fightcade-web:"
    + digest
)

# Optional expensive version probe.
#
# Usage:
#   fightcade_web_identity.py
#       -> identity only, fast
#
#   fightcade_web_identity.py --version
#       -> stream archive and read VERSION.txt
#
if len(sys.argv) > 1 and sys.argv[1] == "--version":
    pipeline = (
        f'curl -fsSL "{URL}" '
        '| tar -xOzf - Fightcade/VERSION.txt'
    )

    version = subprocess.check_output(
        [
            "bash",
            "-c",
            pipeline,
        ],
        text=True,
    ).strip()

    if not version:
        raise SystemExit(
            "Unable to determine Fightcade version"
        )

    print(version)
    print(identity)

else:
    print(identity)
