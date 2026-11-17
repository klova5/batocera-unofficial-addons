#!/usr/bin/env python3

import json
import re
from pathlib import Path
from urllib.parse import urlparse

ROOT = Path("/userdata/system/add-ons/bua/updater")

MANIFEST = (
    ROOT
    / "catalog/global/global-update-manifest.json"
)

RESOLUTION = (
    ROOT
    / "catalog/global/github-release-repo-resolution.json"
)

OUT = (
    ROOT
    / "catalog/global/github-parent-source-audit.json"
)

with MANIFEST.open() as f:
    manifest = json.load(f)

with RESOLUTION.open() as f:
    resolved = json.load(f)

manifest_by_app = {
    a["app"]: a
    for a in manifest["apps"]
}

MIRROR_OWNERS = {
    "batocera-unofficial-addons",
}

MIRROR_REPO_PATTERNS = [
    r"batocera",
    r"appimages?",
    r"interface",
    r"\.drl$",
    r"\.add$",
]

SUSPICIOUS_TAGS = {
    "appimages",
    "files",
}

APP_PARENT_HOSTS = {
    "github.com",
    "api.github.com",
    "gitlab.com",
    "sourceforge.net",
}


def mirror_score(owner, repo, tag):
    score = 0
    reasons = []

    owner_l = (owner or "").lower()
    repo_l = (repo or "").lower()
    tag_l = (tag or "").lower()

    if owner_l in MIRROR_OWNERS:
        score += 100
        reasons.append("known_bua_owner")

    for pattern in MIRROR_REPO_PATTERNS:
        if re.search(pattern, repo_l):
            score += 30
            reasons.append(
                f"mirror_repo_pattern:{pattern}"
            )

    if tag_l in SUSPICIOUS_TAGS:
        score += 50
        reasons.append(
            f"suspicious_release_tag:{tag}"
        )

    return score, reasons


def useful_urls(item):
    urls = item.get("external_urls") or []

    result = []

    for url in urls:
        try:
            host = urlparse(url).netloc.lower()
        except Exception:
            continue

        result.append({
            "url": url,
            "host": host,
        })

    return result


results = []

for entry in resolved["results"]:
    app = entry["app"]
    manifest_item = manifest_by_app[app]
    chosen = entry.get("chosen")

    record = {
        "app": app,
        "resolution_status": entry["status"],
        "chosen": chosen,
        "classification": None,
        "mirror_score": None,
        "reasons": [],
        "external_urls": useful_urls(
            manifest_item
        ),
        "installer_path": manifest_item.get(
            "installer_path"
        ),
    }

    if not chosen:
        record["classification"] = (
            "needs_other_source"
        )
        record["reasons"].append(
            "no_verified_github_release_repo"
        )
        results.append(record)
        continue

    verification = chosen.get(
        "verification"
    ) or {}

    tag = verification.get(
        "tag_name"
    )

    score, reasons = mirror_score(
        chosen.get("owner"),
        chosen.get("repo"),
        tag,
    )

    record["mirror_score"] = score
    record["reasons"].extend(reasons)

    if score >= 50:
        record["classification"] = (
            "distribution_or_mirror"
        )
    else:
        record["classification"] = (
            "probable_parent"
        )

    results.append(record)


payload = {
    "total": len(results),
    "probable_parent": sum(
        r["classification"] == "probable_parent"
        for r in results
    ),
    "distribution_or_mirror": sum(
        r["classification"]
        == "distribution_or_mirror"
        for r in results
    ),
    "needs_other_source": sum(
        r["classification"]
        == "needs_other_source"
        for r in results
    ),
    "results": results,
}

OUT.write_text(
    json.dumps(
        payload,
        indent=2,
        sort_keys=True,
    )
)

print(
    f'TOTAL={payload["total"]} '
    f'PARENT={payload["probable_parent"]} '
    f'MIRROR={payload["distribution_or_mirror"]} '
    f'OTHER={payload["needs_other_source"]}'
)

print()

for r in results:
    chosen = r.get("chosen") or {}

    verification = (
        chosen.get("verification") or {}
    )

    print(
        f'{r["app"]:<30} '
        f'{r["classification"]:<24} '
        f'{chosen.get("owner", "-")}/'
        f'{chosen.get("repo", "-")} '
        f'tag={verification.get("tag_name", "-")}'
    )

    if r["classification"] != "probable_parent":
        for reason in r["reasons"]:
            print(
                f"    reason: {reason}"
            )

        for item in r["external_urls"]:
            print(
                f'    url: {item["url"]}'
            )
