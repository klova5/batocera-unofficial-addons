#!/usr/bin/env python3

import hashlib
import re
import urllib.request

URL = "https://downloads.videolan.org/vlc/last/"

req = urllib.request.Request(
    URL,
    headers={
        "User-Agent": "Mozilla/5.0 BUA-Updater",
        "Cache-Control": "no-cache",
    },
)

with urllib.request.urlopen(
    req,
    timeout=25,
) as response:
    text = response.read().decode(
        "utf-8",
        errors="replace",
    )

matches = sorted(
    set(
        re.findall(
            r'vlc-([0-9]+\.[0-9]+\.[0-9]+)\.tar\.xz',
            text,
        )
    )
)

if not matches:
    raise SystemExit(
        "Unable to determine VLC version"
    )

def version_key(value):
    return tuple(
        int(part)
        for part in value.split(".")
    )

version = max(
    matches,
    key=version_key,
)

# Fingerprint the relevant upstream directory listing so a
# same-version artifact replacement can still be detected.
relevant = sorted(
    line.strip()
    for line in text.splitlines()
    if (
        f"vlc-{version}" in line
        or "sha256" in line.lower()
    )
)

payload = "\n".join(
    relevant
).encode("utf-8")

digest = hashlib.sha256(
    payload
).hexdigest()

print(version)
print(
    f"videolan-last:{version}:{digest}"
)
