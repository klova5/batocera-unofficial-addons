#!/usr/bin/env python3

import hashlib
import html
import re
import urllib.request

URL = "https://madgarden.itch.io/eggnogg"

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

text = html.unescape(text)

updated_patterns = [
    re.compile(
        r'Updated[^0-9]+'
        r'([0-9]{1,2}\s+[A-Za-z]+\s+[0-9]{4}\s*@\s*'
        r'[0-9]{1,2}:[0-9]{2}\s*UTC)',
        re.I | re.S,
    ),
    re.compile(
        r'Updated\s+[^<\n]*\('
        r'([^)]+UTC)'
        r'\)',
        re.I,
    ),
]

updated = None

for pattern in updated_patterns:
    match = pattern.search(text)

    if match:
        updated = match.group(1).strip()
        break

if not updated:
    raise SystemExit(
        "Unable to determine itch.io update timestamp"
    )

linux_match = re.search(
    r'EGGNOGG\+\s+Linux'
    r'.{0,200}?'
    r'([0-9]+(?:\.[0-9]+)?\s*'
    r'(?:kB|KB|MB|MiB))',
    text,
    re.I | re.S,
)

linux_size = (
    linux_match.group(1).strip()
    if linux_match
    else "unknown"
)

payload = "\n".join(
    [
        updated,
        "EGGNOGG+ Linux",
        linux_size,
    ]
).encode("utf-8")

digest = hashlib.sha256(
    payload
).hexdigest()

print("rolling")
print(
    f"itch-eggnogg:{digest}"
)
print(updated)
print(linux_size)
