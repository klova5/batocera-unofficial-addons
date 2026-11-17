#!/usr/bin/env python3

import hashlib
import platform
import re
import urllib.request


PAGE = "https://wohlsoft.ru/projects/TheXTech/"

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
    r'Current stable version:\s*([0-9]+(?:\.[0-9]+)+)',
    html,
    re.I,
)

if not m:
    raise SystemExit(
        "Unable to determine current TheXTech stable version"
    )

version = m.group(1)

machine = platform.machine()

if machine in ("x86_64", "amd64"):
    suffix = "linux-generic-u24.04-amd64.tar.gz"
elif machine in ("aarch64", "arm64"):
    suffix = "linux-generic-u20.04-aarch64.tar.gz"
else:
    raise SystemExit(
        "Unsupported Super Mario X architecture: "
        + machine
    )


pattern = re.compile(
    r'https://wohlsoft\.ru/projects/TheXTech/_downloads/releases/'
    r'(super-mario-bros-x-thextech-v'
    + re.escape(version)
    + r'-'
    + re.escape(suffix)
    + r')'
)

m = pattern.search(html)

if not m:
    raise SystemExit(
        "Matching Super Mario X artifact not found"
    )

filename = m.group(1)

url = (
    "https://wohlsoft.ru/projects/TheXTech/_downloads/releases/"
    + filename
)


head = urllib.request.Request(
    url,
    method="HEAD",
    headers={
        "User-Agent": "BUA-Updater",
        "Cache-Control": "no-cache",
    },
)

with urllib.request.urlopen(
    head,
    timeout=30,
) as response:
    etag = str(
        response.headers.get("ETag")
        or ""
    ).strip()

    modified = str(
        response.headers.get("Last-Modified")
        or ""
    ).strip()

    length = str(
        response.headers.get("Content-Length")
        or ""
    ).strip()


normalized = "\n".join(
    [
        version,
        filename,
        url,
        etag,
        modified,
        length,
    ]
).encode("utf-8")

digest = hashlib.sha256(
    normalized
).hexdigest()


print(version)

print(
    "thextech-smbx:"
    + machine
    + ":"
    + version
    + ":"
    + filename
    + ":"
    + digest
)
