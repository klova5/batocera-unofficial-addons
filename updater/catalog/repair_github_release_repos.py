#!/usr/bin/env python3

import json
import re
import urllib.request
from pathlib import Path

ROOT = Path("/userdata/system/add-ons/bua/updater")

MANIFEST = (
    ROOT
    / "catalog/global/global-update-manifest.json"
)

OUT = (
    ROOT
    / "catalog/global/"
      "github-release-repo-resolution.json"
)

with MANIFEST.open() as f:
    data = json.load(f)


PATTERNS = [
    (
        "api",
        re.compile(
            r'https?://api\.github\.com/repos/'
            r'([^/"\s]+)/([^/"\s]+)/releases',
            re.I,
        ),
    ),
    (
        "release_download",
        re.compile(
            r'https?://github\.com/'
            r'([^/"\s]+)/([^/"\s]+)/'
            r'releases/download(?:/|["\'\s]|$)',
            re.I,
        ),
    ),
    (
        "release_latest",
        re.compile(
            r'https?://github\.com/'
            r'([^/"\s]+)/([^/"\s]+)/'
            r'releases/latest(?:/|["\'\s]|$)',
            re.I,
        ),
    ),
    (
        "release_tag",
        re.compile(
            r'https?://github\.com/'
            r'([^/"\s]+)/([^/"\s]+)/'
            r'releases/tag(?:/|["\'\s]|$)',
            re.I,
        ),
    ),
    (
        "releases_root",
        re.compile(
            r'https?://github\.com/'
            r'([^/"\s]+)/([^/"\s]+)/releases'
            r'(?:/|["\'\s]|$)',
            re.I,
        ),
    ),
]


def clean_repo(repo):
    repo = repo.rstrip(
        '.,;:\'"\\'
    )

    if repo.endswith(".git"):
        repo = repo[:-4]

    return repo


def candidates_from_script(script):
    candidates = {}

    for source, pattern in PATTERNS:
        for match in pattern.finditer(script):
            owner = match.group(1)
            repo = clean_repo(
                match.group(2)
            )

            key = (
                owner.lower(),
                repo.lower(),
            )

            item = candidates.setdefault(
                key,
                {
                    "owner": owner,
                    "repo": repo,
                    "sources": set(),
                    "count": 0,
                },
            )

            item["sources"].add(source)
            item["count"] += 1

    results = []

    for item in candidates.values():
        item["sources"] = sorted(
            item["sources"]
        )
        results.append(item)

    return results


def verify_latest(owner, repo):
    url = (
        "https://api.github.com/repos/"
        f"{owner}/{repo}/releases/latest"
    )

    req = urllib.request.Request(
        url,
        headers={
            "User-Agent": "BUA-Updater-Audit",
            "Accept": "application/vnd.github+json",
            "Cache-Control": "no-cache",
        },
    )

    try:
        with urllib.request.urlopen(
            req,
            timeout=20,
        ) as response:
            release = json.loads(
                response.read().decode("utf-8")
            )

        tag = str(
            release.get("tag_name") or ""
        ).strip()

        if not tag:
            return {
                "ok": False,
                "error": "no tag_name",
            }

        return {
            "ok": True,
            "tag_name": tag,
            "release_id": release.get("id"),
            "url": url,
        }

    except Exception as exc:
        return {
            "ok": False,
            "error": (
                f"{type(exc).__name__}: {exc}"
            ),
            "url": url,
        }


def score(item):
    sources = set(
        item["sources"]
    )

    value = 0

    if "api" in sources:
        value += 100

    if "release_download" in sources:
        value += 80

    if "release_latest" in sources:
        value += 70

    if "release_tag" in sources:
        value += 60

    if "releases_root" in sources:
        value += 40

    value += min(
        item["count"],
        10,
    )

    return value


targets = [
    app
    for app in data["apps"]
    if (
        app.get("source_family")
        == "github_release_download"
    )
]

results = []

for index, app in enumerate(
    targets,
    1,
):
    name = app["app"]

    cached = app.get(
        "cached_installer"
    )

    print(
        f"[{index:02d}/{len(targets):02d}] "
        f"{name}"
    )

    result = {
        "app": name,
        "installer_path": app.get(
            "installer_path"
        ),
        "old_owner": app.get(
            "github_owner"
        ),
        "old_repo": app.get(
            "github_repo"
        ),
        "candidates": [],
        "chosen": None,
        "status": None,
    }

    if (
        not cached
        or not Path(cached).is_file()
    ):
        result["status"] = (
            "cached_installer_missing"
        )
        results.append(result)
        continue

    script = Path(cached).read_text(
        errors="replace"
    )

    candidates = candidates_from_script(
        script
    )

    for candidate in candidates:
        candidate["score"] = score(
            candidate
        )

        candidate["verification"] = (
            verify_latest(
                candidate["owner"],
                candidate["repo"],
            )
        )

    candidates.sort(
        key=lambda x: (
            not x["verification"]["ok"],
            -x["score"],
            x["owner"].lower(),
            x["repo"].lower(),
        )
    )

    result["candidates"] = candidates

    valid = [
        c for c in candidates
        if c["verification"]["ok"]
    ]

    if not valid:
        result["status"] = (
            "no_verified_release_repo"
        )

    elif len(valid) == 1:
        result["chosen"] = valid[0]
        result["status"] = "resolved"

    else:
        best = valid[0]

        if (
            len(valid) > 1
            and best["score"]
            == valid[1]["score"]
        ):
            result["status"] = (
                "ambiguous"
            )
        else:
            result["chosen"] = best
            result["status"] = "resolved"

    results.append(result)


OUT.write_text(
    json.dumps(
        {
            "total": len(results),
            "resolved": sum(
                1
                for r in results
                if r["status"] == "resolved"
            ),
            "ambiguous": sum(
                1
                for r in results
                if r["status"] == "ambiguous"
            ),
            "unresolved": sum(
                1
                for r in results
                if r["status"]
                not in (
                    "resolved",
                    "ambiguous",
                )
            ),
            "results": results,
        },
        indent=2,
        sort_keys=True,
    )
)

print()
print(f"REPORT={OUT}")
