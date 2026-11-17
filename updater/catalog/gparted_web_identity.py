#!/usr/bin/env python3

import hashlib
import re
import urllib.request

URL = "https://gparted.org/"

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

match = re.search(
    r'Stable\s+release:\s*'
    r'(?:<[^>]+>\s*)*'
    r'GParted\s+'
    r'([0-9]+\.[0-9]+\.[0-9]+)',
    text,
    re.I | re.S,
)

if not match:
    # More tolerant fallback for minor HTML changes.
    match = re.search(
        r'GParted\s+([0-9]+\.[0-9]+\.[0-9]+)',
        text,
        re.I,
    )

if not match:
    raise SystemExit(
        "Unable to determine GParted stable version"
    )

version = match.group(1)

# Fingerprint only the relevant stable-release portion,
# rather than the entire site.
relevant = sorted(
    line.strip()
    for line in text.splitlines()
    if (
        "Stable release" in line
        or f"GParted {version}" in line
    )
)

digest = hashlib.sha256(
    "\n".join(relevant).encode("utf-8")
).hexdigest()

print(version)
print(
    f"gparted-web:{version}:{digest}"
)
