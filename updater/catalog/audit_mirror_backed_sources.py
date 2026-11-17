#!/usr/bin/env python3

import json
import re
from collections import Counter
from pathlib import Path
from urllib.parse import urlparse

ROOT = Path("/userdata/system/add-ons/bua/updater")

MANIFEST = (
    ROOT
    / "catalog/global/global-update-manifest.json"
)

PARENT_AUDIT = (
    ROOT
    / "catalog/global/github-parent-source-audit.json"
)

OUT = (
    ROOT
    / "catalog/global/mirror-backed-source-audit.json"
)

with MANIFEST.open() as f:
    manifest = json.load(f)

with PARENT_AUDIT.open() as f:
    parent_audit = json.load(f)

manifest_by_app = {
    item["app"]: item
    for item in manifest["apps"]
}

targets = [
    item["app"]
    for item in parent_audit["results"]
    if item.get("classification")
    == "distribution_or_mirror"
]

URL_RE = re.compile(
    r'https?://[^\s\'"<>]+',
    re.I,
)

ASSIGN_RE = re.compile(
    r'(?m)^[ \t]*(?:export[ \t]+)?'
    r'([A-Za-z_][A-Za-z0-9_]*)='
    r'(?:"([^"\n]*)"|\'([^\'\n]*)\'|([^\s#;]+))'
)

GITHUB_RE = re.compile(
    r'https?://(?:api\.)?github\.com/'
    r'(?:repos/)?([^/"\s]+)/([^/"\s]+)',
    re.I,
)

RELEVANT_ASSIGN_WORDS = (
    "URL",
    "REPO",
    "API",
    "VERSION",
    "RELEASE",
    "DOWNLOAD",
    "SOURCE",
    "HOST",
    "APPIMAGE",
    "FLATPAK",
    "PACKAGE",
)

IGNORE_DOMAINS = {
    "127.0.0.1",
    "localhost",
    "raw.githubusercontent.com",
    "githubusercontent.com",
}

KNOWN_MIRROR_OWNERS = {
    "batocera-unofficial-addons",
    "drledition19",
}


def clean_url(url):
    return url.rstrip(
        '.,;:)\\]\'"'
    )


def domain(url):
    try:
        return urlparse(url).netloc.lower()
    except Exception:
        return ""


def assignments(script):
    values = {}

    for match in ASSIGN_RE.finditer(script):
        name = match.group(1)

        value = next(
            (
                g
                for g in match.groups()[1:]
                if g is not None
            ),
            "",
        )

        if any(
            word in name.upper()
            for word in RELEVANT_ASSIGN_WORDS
        ):
            values[name] = value

    return values


def github_candidates(script):
    found = {}

    for match in GITHUB_RE.finditer(script):
        owner = match.group(1)
        repo = match.group(2)

        repo = repo.rstrip(
            '.,;:)\\]\'"'
        )

        # Trim known path suffixes accidentally captured.
        repo = repo.split("/")[0]

        if repo.endswith(".git"):
            repo = repo[:-4]

        if (
            "$" in owner
            or "$" in repo
        ):
            continue

        key = (
            owner.lower(),
            repo.lower(),
        )

        found[key] = {
            "owner": owner,
            "repo": repo,
            "mirror_like": (
                owner.lower()
                in KNOWN_MIRROR_OWNERS
            ),
        }

    return list(
        found.values()
    )


def command_context(script):
    lines = script.splitlines()

    interesting = []

    for number, line in enumerate(
        lines,
        1,
    ):
        lower = line.lower()

        if not any(
            token in lower
            for token in (
                "curl ",
                "wget ",
                "flatpak ",
                "appimage",
                "release",
                "version",
                "download",
                "sourceforge",
                "github",
                "api.",
            )
        ):
            continue

        stripped = line.strip()

        if not stripped:
            continue

        interesting.append({
            "line": number,
            "text": stripped[:300],
        })

    return interesting[:40]


results = []

print(
    f"Mirror-backed targets: "
    f"{len(targets)}"
)
print()

for index, app in enumerate(
    targets,
    1,
):
    item = manifest_by_app[app]

    cached = item.get(
        "cached_installer"
    )

    record = {
        "app": app,
        "installer_path": item.get(
            "installer_path"
        ),
        "cached_installer": cached,
        "domains": [],
        "urls": [],
        "assignments": {},
        "github_candidates": [],
        "command_context": [],
        "suggested_family": None,
    }

    print(
        f"[{index:02d}/{len(targets):02d}] "
        f"{app}"
    )

    if (
        not cached
        or not Path(cached).is_file()
    ):
        record["suggested_family"] = (
            "cache_missing"
        )
        results.append(record)
        continue

    script = Path(cached).read_text(
        errors="replace"
    )

    urls = [
        clean_url(u)
        for u in URL_RE.findall(script)
    ]

    urls = list(dict.fromkeys(urls))

    counts = Counter(
        d
        for d in (
            domain(url)
            for url in urls
        )
        if d
    )

    record["domains"] = [
        {
            "domain": name,
            "count": count,
        }
        for name, count
        in counts.most_common()
    ]

    record["urls"] = urls
    record["assignments"] = (
        assignments(script)
    )

    record["github_candidates"] = (
        github_candidates(script)
    )

    record["command_context"] = (
        command_context(script)
    )

    nonmirror_github = [
        c
        for c in record[
            "github_candidates"
        ]
        if not c["mirror_like"]
    ]

    domains = {
        d["domain"]
        for d in record["domains"]
    }

    if nonmirror_github:
        record["suggested_family"] = (
            "inspect_github_parent"
        )

    elif any(
        "sourceforge.net" in d
        for d in domains
    ):
        record["suggested_family"] = (
            "sourceforge"
        )

    elif (
        "flathub.org" in domains
        or "dl.flathub.org" in domains
    ):
        record["suggested_family"] = (
            "flathub"
        )

    else:
        external = [
            d
            for d in domains
            if (
                d not in IGNORE_DOMAINS
                and "batocera-unofficial-addons"
                not in d
                and "github.com" not in d
            )
        ]

        if external:
            record["suggested_family"] = (
                "inspect_vendor_web"
            )
        else:
            record["suggested_family"] = (
                "bua_component_or_custom"
            )

    results.append(record)


payload = {
    "total": len(results),
    "results": results,
}

OUT.write_text(
    json.dumps(
        payload,
        indent=2,
        sort_keys=True,
    )
)

print()
print(f"REPORT={OUT}")
