#!/usr/bin/env python3

import hashlib
import html
import re
import sys
import urllib.request


OWNER = "AzaharPlus"
REPO = "shadPS4Plus"

RELEASES_URL = (
    f"https://github.com/{OWNER}/{REPO}/releases"
)

TAG_RE = re.compile(
    rf"/{re.escape(OWNER)}/{re.escape(REPO)}/releases/tag/"
    r"([^\"'<>\s]+)"
)

VALID_PATTERNS = (
    re.compile(r"^SHAD_PS4_PLUS_", re.I),
    re.compile(r"^SHADPS4PLUS_", re.I),
)


def request(url):
    req = urllib.request.Request(
        url,
        headers={
            "User-Agent": "BUA-Updater",
            "Cache-Control": "no-cache",
        },
    )

    with urllib.request.urlopen(
        req,
        timeout=25,
    ) as response:
        return response.read().decode(
            "utf-8",
            errors="replace",
        )


def version_key(tag):
    nums = re.findall(
        r"\d+",
        tag,
    )

    return tuple(
        int(x)
        for x in nums
    )


page = request(
    RELEASES_URL
)

tags = []

for raw in TAG_RE.findall(page):
    tag = html.unescape(raw)

    if not any(
        p.search(tag)
        for p in VALID_PATTERNS
    ):
        continue

    if tag not in tags:
        tags.append(tag)

if not tags:
    raise SystemExit(
        "No ShadPS4Plus emulator release tags found"
    )

tag = max(
    tags,
    key=version_key,
)

assets_url = (
    f"https://github.com/{OWNER}/{REPO}/"
    f"releases/expanded_assets/{tag}"
)

assets_page = request(
    assets_url
)

assets = sorted(
    set(
        re.findall(
            r'href="([^"]+/releases/download/'
            + re.escape(tag)
            + r'/[^"]+)"',
            assets_page,
            re.I,
        )
    )
)

normalized = "\n".join(
    [
        tag,
        *assets,
    ]
).encode("utf-8")

digest = hashlib.sha256(
    normalized
).hexdigest()

linux_assets = [
    asset
    for asset in assets
    if re.search(
        r"linux[^/]*\.zip$",
        asset,
        re.I,
    )
]

if not linux_assets:
    raise SystemExit(
        "No ShadPS4Plus Linux release archive found"
    )

payload_path = linux_assets[0]

if payload_path.startswith("http://") or payload_path.startswith("https://"):
    payload_url = payload_path
else:
    payload_url = "https://github.com" + payload_path

print(tag)

print(
    f"github-filtered:{tag}:{digest}"
)

print(payload_url)
