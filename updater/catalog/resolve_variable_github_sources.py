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

AUDIT = (
    ROOT
    / "catalog/global/github-parent-source-audit.json"
)

OUT = (
    ROOT
    / "catalog/global/variable-github-resolution.json"
)

with MANIFEST.open() as f:
    manifest = json.load(f)

with AUDIT.open() as f:
    audit = json.load(f)

manifest_by_app = {
    item["app"]: item
    for item in manifest["apps"]
}


ASSIGNMENT_RE = re.compile(
    r'(?m)^[ \t]*(?:export[ \t]+)?'
    r'([A-Za-z_][A-Za-z0-9_]*)='
    r'(?:"([^"\n]*)"|\'([^\'\n]*)\'|([^\s#;]+))'
)


def parse_assignments(script):
    values = {}

    for match in ASSIGNMENT_RE.finditer(script):
        name = match.group(1)

        value = next(
            (
                group
                for group in match.groups()[1:]
                if group is not None
            ),
            "",
        )

        values[name] = value

    # Expand simple $VAR / ${VAR} references iteratively.
    for _ in range(10):
        changed = False

        for name, value in list(values.items()):
            new = value

            for other, other_value in values.items():
                new = new.replace(
                    "${" + other + "}",
                    other_value,
                )

                new = re.sub(
                    rf'\${re.escape(other)}\b',
                    lambda m, v=other_value: v,
                    new,
                )

            if new != value:
                values[name] = new
                changed = True

        if not changed:
            break

    return values


def expand_script(script, variables):
    expanded = script

    # Longest names first prevents partial collisions.
    for name in sorted(
        variables,
        key=len,
        reverse=True,
    ):
        value = variables[name]

        expanded = expanded.replace(
            "${" + name + "}",
            value,
        )

        expanded = re.sub(
            rf'\${re.escape(name)}\b',
            lambda m, v=value: v,
            expanded,
        )

    return expanded


REPO_PATTERNS = [
    re.compile(
        r'api\.github\.com/repos/'
        r'([^/"\s]+)/([^/"\s]+)/releases',
        re.I,
    ),
    re.compile(
        r'github\.com/'
        r'([^/"\s]+)/([^/"\s]+)/releases',
        re.I,
    ),
]


def candidate_repos(expanded):
    found = {}

    for pattern in REPO_PATTERNS:
        for match in pattern.finditer(expanded):
            owner = match.group(1)
            repo = match.group(2)

            repo = repo.rstrip(
                '.,;:\'"\\'
            )

            if repo.endswith(".git"):
                repo = repo[:-4]

            if "$" in owner or "$" in repo:
                continue

            key = (
                owner.lower(),
                repo.lower(),
            )

            found[key] = {
                "owner": owner,
                "repo": repo,
            }

    return list(found.values())


def verify_release_page(owner, repo):
    """
    Verify through github.com rather than the API to avoid
    burning API rate-limit quota during discovery.
    """
    url = (
        f"https://github.com/{owner}/{repo}/"
        "releases/latest"
    )

    request = urllib.request.Request(
        url,
        headers={
            "User-Agent": "Mozilla/5.0 BUA-Updater-Audit",
        },
        method="HEAD",
    )

    try:
        with urllib.request.urlopen(
            request,
            timeout=20,
        ) as response:
            final_url = response.geturl()

        match = re.search(
            r'/releases/tag/([^/?#]+)',
            final_url,
        )

        tag = (
            match.group(1)
            if match
            else None
        )

        return {
            "ok": bool(tag),
            "tag": tag,
            "final_url": final_url,
        }

    except Exception as exc:
        return {
            "ok": False,
            "error": (
                f"{type(exc).__name__}: {exc}"
            ),
            "url": url,
        }


targets = [
    item
    for item in audit["results"]
    if item["classification"] == "needs_other_source"
]

results = []

print(f"Targets={len(targets)}")
print()

for index, audit_item in enumerate(targets, 1):
    app = audit_item["app"]

    manifest_item = manifest_by_app[app]

    cached = manifest_item.get(
        "cached_installer"
    )

    result = {
        "app": app,
        "variables": {},
        "candidates": [],
        "status": None,
        "chosen": None,
    }

    print(
        f"[{index:02d}/{len(targets):02d}] {app}"
    )

    if (
        not cached
        or not Path(cached).is_file()
    ):
        result["status"] = "cache_missing"
        results.append(result)
        continue

    script = Path(cached).read_text(
        errors="replace"
    )

    variables = parse_assignments(
        script
    )

    result["variables"] = {
        k: v
        for k, v in variables.items()
        if (
            "REPO" in k.upper()
            or "GITHUB" in k.upper()
            or "PROJECT" in k.upper()
            or "OWNER" in k.upper()
        )
    }

    expanded = expand_script(
        script,
        variables,
    )

    candidates = candidate_repos(
        expanded
    )

    for candidate in candidates:
        candidate["verification"] = (
            verify_release_page(
                candidate["owner"],
                candidate["repo"],
            )
        )

    result["candidates"] = candidates

    valid = [
        c
        for c in candidates
        if c["verification"]["ok"]
    ]

    if len(valid) == 1:
        result["chosen"] = valid[0]
        result["status"] = "resolved"

    elif len(valid) > 1:
        result["status"] = "ambiguous"

    else:
        result["status"] = "unresolved"

    results.append(result)


payload = {
    "total": len(results),
    "resolved": sum(
        r["status"] == "resolved"
        for r in results
    ),
    "ambiguous": sum(
        r["status"] == "ambiguous"
        for r in results
    ),
    "unresolved": sum(
        r["status"] == "unresolved"
        for r in results
    ),
    "other": sum(
        r["status"]
        not in (
            "resolved",
            "ambiguous",
            "unresolved",
        )
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

print()
print(
    f'RESOLVED={payload["resolved"]} '
    f'AMBIGUOUS={payload["ambiguous"]} '
    f'UNRESOLVED={payload["unresolved"]} '
    f'OTHER={payload["other"]}'
)

print(f"REPORT={OUT}")
