#!/usr/bin/env python3

import hashlib
import platform
import re
import urllib.parse
import urllib.request
from html.parser import HTMLParser


PAGE = "https://openrgb.org/releases.html"


class LinkParser(HTMLParser):
    def __init__(self):
        super().__init__()
        self.links = []

    def handle_starttag(self, tag, attrs):
        if tag.lower() != "a":
            return

        href = dict(attrs).get("href")

        if href:
            self.links.append(href)


machine = platform.machine()

if machine in ("x86_64", "amd64"):
    arch = "x86_64"
elif machine in ("aarch64", "arm64"):
    arch = "arm64"
else:
    raise SystemExit(
        "Unsupported OpenRGB architecture: "
        + machine
    )


req = urllib.request.Request(
    PAGE,
    headers={
        "User-Agent": "BUA-Updater",
        "Cache-Control": "no-cache",
    },
)

with urllib.request.urlopen(
    req,
    timeout=25,
) as response:
    page = response.read().decode(
        "utf-8",
        errors="replace",
    )


release_match = re.search(
    r'Release\s+([0-9]+(?:\.[0-9]+)+)',
    page,
    re.I,
)

if not release_match:
    raise SystemExit(
        "Unable to determine OpenRGB release version"
    )

version = release_match.group(1)


parser = LinkParser()
parser.feed(page)


filename_re = re.compile(
    rf'^OpenRGB_'
    rf'{re.escape(version)}_'
    rf'{re.escape(arch)}_'
    r'[^/]+\.AppImage$',
    re.I,
)


candidates = []

for href in parser.links:
    absolute = urllib.parse.urljoin(
        PAGE,
        href,
    )

    path = urllib.parse.urlparse(
        absolute
    ).path

    filename = urllib.parse.unquote(
        path.rsplit("/", 1)[-1]
    )

    if filename_re.fullmatch(filename):
        candidates.append(
            (
                filename,
                absolute,
            )
        )


# Remove exact duplicates while preserving order.
seen = set()
unique = []

for item in candidates:
    if item in seen:
        continue

    seen.add(item)
    unique.append(item)


if not unique:
    raise SystemExit(
        "Unable to find OpenRGB "
        + arch
        + " AppImage for release "
        + version
    )


# Prefer a normal stable release artifact.
# Do not accept pipeline, RC, armhf, i386, etc.
stable = [
    item
    for item in unique
    if "pipeline" not in item[1].lower()
    and "rc" not in item[0].lower()
]

if stable:
    unique = stable


filename, asset_url = unique[0]


normalized = (
    version
    + "\n"
    + arch
    + "\n"
    + filename
    + "\n"
    + asset_url
).encode("utf-8")

digest = hashlib.sha256(
    normalized
).hexdigest()


print(version)

print(
    "openrgb:"
    + arch
    + ":"
    + version
    + ":"
    + filename
    + ":"
    + digest
)
