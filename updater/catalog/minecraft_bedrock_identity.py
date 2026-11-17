#!/usr/bin/env python3

import platform
import re
import urllib.request
import json
import hashlib


OWNER = "minecraft-linux"
REPO = "appimage-builder"

machine = platform.machine()

if machine in ("x86_64", "amd64"):
    arch_token = "x86_64"
elif machine in ("aarch64", "arm64"):
    arch_token = "arm64"
else:
    raise SystemExit(
        "Unsupported Minecraft Bedrock architecture: "
        + machine
    )


url = (
    "https://api.github.com/repos/"
    + OWNER
    + "/"
    + REPO
    + "/releases/latest"
)

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
    data = json.load(response)


tag = str(
    data.get("tag_name")
    or ""
).strip()

if not tag:
    raise SystemExit(
        "Minecraft Bedrock release tag unavailable"
    )


matches = []

for asset in data.get("assets", []):
    name = str(
        asset.get("name")
        or ""
    )

    download_url = str(
        asset.get("browser_download_url")
        or ""
    )

    lower = name.lower()

    if arch_token.lower() not in lower:
        continue

    if not lower.endswith(".appimage"):
        continue

    if "bookworm" in lower:
        continue

    matches.append(
        (
            name,
            download_url,
        )
    )


if not matches:
    raise SystemExit(
        "No matching Minecraft Bedrock AppImage found"
    )


# BUA effectively expects one matching artifact.
name, download_url = matches[0]


normalized = (
    tag
    + "\n"
    + arch_token
    + "\n"
    + name
    + "\n"
    + download_url
).encode("utf-8")

digest = hashlib.sha256(
    normalized
).hexdigest()


print(tag)

print(
    "minecraft-bedrock:"
    + arch_token
    + ":"
    + tag
    + ":"
    + name
    + ":"
    + digest
)
