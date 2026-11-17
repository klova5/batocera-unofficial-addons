#!/usr/bin/env python3

import json
import urllib.request

OWNER = "nicolai-6"
REPO = "batocera-nvidia-clocker"
BRANCH = "main"

url = (
    f"https://api.github.com/repos/"
    f"{OWNER}/{REPO}/commits/{BRANCH}"
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

sha = str(data.get("sha") or "").strip()

if not sha:
    raise SystemExit(
        "Unable to resolve NVIDIA Clocker main branch SHA"
    )

print("rolling")
print(
    f"github-branch:{OWNER}:{REPO}:{BRANCH}:{sha}"
)
