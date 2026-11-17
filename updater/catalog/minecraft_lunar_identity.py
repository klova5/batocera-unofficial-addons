#!/usr/bin/env python3

import hashlib
import re
import urllib.parse
import urllib.request


URL = "https://api.lunarclientprod.com/site/download?os=linux"

req = urllib.request.Request(
    URL,
    method="HEAD",
    headers={
        "User-Agent": "BUA-Updater",
        "Cache-Control": "no-cache",
    },
)

with urllib.request.urlopen(
    req,
    timeout=25,
) as response:
    final_url = response.geturl()

    headers = response.headers

    etag = str(
        headers.get("ETag")
        or ""
    ).strip()

    modified = str(
        headers.get("Last-Modified")
        or ""
    ).strip()

    length = str(
        headers.get("Content-Length")
        or ""
    ).strip()


filename = urllib.parse.unquote(
    urllib.parse.urlparse(
        final_url
    ).path.rsplit("/", 1)[-1]
)

match = re.search(
    r'Lunar Client-([0-9]+(?:\.[0-9]+)+)-',
    filename,
    re.I,
)

if not match:
    raise SystemExit(
        "Unable to determine Lunar Client version "
        "from " + filename
    )

version = match.group(1)


normalized = "\n".join(
    [
        version,
        filename,
        final_url,
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
    "minecraft-lunar:"
    + version
    + ":"
    + filename
    + ":"
    + digest
)
