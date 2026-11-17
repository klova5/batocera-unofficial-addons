#!/usr/bin/env python3

import re
import urllib.request

OWNER = "git-developer"
REPO = "batocera-extra"
BRANCH = "main"

URL = (
    f"https://github.com/{OWNER}/{REPO}/"
    f"commits/{BRANCH}.atom"
)

req = urllib.request.Request(
    URL,
    headers={
        "User-Agent": "BUA-Updater",
        "Cache-Control": "no-cache",
    },
)

with urllib.request.urlopen(
    req,
    timeout=30,
) as response:
    text = response.read().decode(
        "utf-8",
        errors="replace",
    )

m = re.search(
    rf'https://github\.com/{re.escape(OWNER)}/'
    rf'{re.escape(REPO)}/commit/([0-9a-f]{{40}})',
    text,
    re.I,
)

if not m:
    raise SystemExit(
        "Unable to resolve batocera-extra main commit"
    )

sha = m.group(1).lower()

print("rolling")

print(
    f"github-branch:{OWNER}:{REPO}:{BRANCH}:{sha}"
)
