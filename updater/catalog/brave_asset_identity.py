#!/usr/bin/env python3

import hashlib
import html
import platform
import re
import urllib.request


OWNER = "srevinsaju"
REPO = "Brave-AppImage"

machine = platform.machine()

if machine not in ("x86_64", "amd64"):
    raise SystemExit(
        "BUA Brave currently supports x86_64 only"
    )

suffix = "x86_64.AppImage"

base = (
    f"https://github.com/{OWNER}/{REPO}"
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


page = request(
    base + "/releases"
)

tag_re = re.compile(
    rf'/{re.escape(OWNER)}/{re.escape(REPO)}'
    r'/releases/tag/([^"\'<>\s]+)'
)

tags = []

for raw in tag_re.findall(page):
    tag = html.unescape(raw)

    if tag not in tags:
        tags.append(tag)


if not tags:
    raise SystemExit(
        "No Brave release tags found"
    )


selected_tag = None
selected_asset = None
selected_url = None


for tag in tags:
    assets_page = request(
        base
        + "/releases/expanded_assets/"
        + tag
    )

    asset_re = re.compile(
        rf'href="([^"]+/releases/download/'
        rf'{re.escape(tag)}/([^"]+))"',
        re.I,
    )

    for rel_url, filename in asset_re.findall(
        assets_page
    ):
        filename = html.unescape(
            filename
        )

        if not filename.endswith(suffix):
            continue

        selected_tag = tag
        selected_asset = filename

        if rel_url.startswith("http"):
            selected_url = rel_url
        else:
            selected_url = (
                "https://github.com"
                + rel_url
            )

        break

    if selected_tag:
        break


if not selected_tag:
    raise SystemExit(
        "No Brave x86_64 AppImage found"
    )


normalized = (
    selected_tag
    + "\n"
    + selected_asset
    + "\n"
    + selected_url
).encode("utf-8")

digest = hashlib.sha256(
    normalized
).hexdigest()


print(selected_tag)

print(
    "github-asset:"
    + selected_tag
    + ":"
    + selected_asset
    + ":"
    + digest
)
