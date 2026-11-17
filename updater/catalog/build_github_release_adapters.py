#!/usr/bin/env python3

import json
import re
import shutil
import subprocess
from pathlib import Path

ROOT = Path("/userdata/system/add-ons/bua/updater")
MANIFEST = ROOT / "catalog/global/global-update-manifest.json"
OUTROOT = ROOT / "converted/github-release-api"
REPORT = ROOT / "catalog/global/github-release-adapter-report.json"

OUTROOT.mkdir(parents=True, exist_ok=True)

with MANIFEST.open() as f:
    data = json.load(f)


def safe_path(item):
    path = item.get("installer_path")

    if path:
        return OUTROOT / path

    slug = re.sub(
        r"[^A-Za-z0-9._-]+",
        "_",
        item["app"],
    ).strip("_")

    return OUTROOT / f"{slug}.sh"


def make_adapter(owner, repo):
    return rf'''
# ===== BUA updater registration adapter =====
bua_github_release_register() {{
    local bua_owner={owner!r}
    local bua_repo={repo!r}

    local bua_values

    bua_values=$(
        python3 - "$bua_owner" "$bua_repo" <<'PYBUAGH'
import hashlib
import json
import sys
import urllib.request

owner, repo = sys.argv[1:3]

url = (
    "https://api.github.com/repos/"
    f"{{owner}}/{{repo}}/releases/latest"
)

req = urllib.request.Request(
    url,
    headers={{
        "User-Agent": "BUA-Updater",
        "Accept": "application/vnd.github+json",
        "Cache-Control": "no-cache",
    }},
)

with urllib.request.urlopen(
    req,
    timeout=25,
) as response:
    release = json.loads(
        response.read().decode("utf-8")
    )

tag = str(
    release.get("tag_name") or ""
).strip()

if not tag:
    raise SystemExit(
        "GitHub release has no tag_name"
    )

assets = []

for asset in release.get("assets") or []:
    assets.append({{
        "id": asset.get("id"),
        "name": asset.get("name"),
        "size": asset.get("size"),
        "updated_at": asset.get("updated_at"),
    }})

identity_payload = {{
    "release_id": release.get("id"),
    "release_updated_at": release.get("updated_at"),
    "assets": sorted(
        assets,
        key=lambda a: (
            str(a.get("name") or ""),
            str(a.get("id") or ""),
        ),
    ),
}}

serialized = json.dumps(
    identity_payload,
    sort_keys=True,
    separators=(",", ":"),
).encode("utf-8")

digest = hashlib.sha256(
    serialized
).hexdigest()

identity = (
    "github-release:"
    + str(release.get("id") or "unknown")
    + ":"
    + digest
)

print(tag)
print(identity)
PYBUAGH
    ) || return 1

    local bua_version
    local bua_identity

    bua_version=$(
        printf '%s\n' "$bua_values" |
            sed -n '1p'
    )

    bua_identity=$(
        printf '%s\n' "$bua_values" |
            sed -n '2p'
    )

    if [[ -z "$bua_version" || -z "$bua_identity" ]]; then
        echo "Unable to determine GitHub release identity." >&2
        return 1
    fi

    bua_register \
        "$bua_version" \
        "github_release" \
        "$bua_owner" \
        "$bua_repo" \
        "custom" \
        "" \
        "" \
        "" \
        "$bua_identity"
}}

if [[ "${{BUA_REGISTRATION_ONLY:-0}}" == "1" ]]; then
    if ! declare -F bua_register >/dev/null 2>&1; then
        echo "BUA registration helper is unavailable." >&2
        exit 1
    fi

    bua_github_release_register
    exit $?
fi
# ===== end BUA updater registration adapter =====

'''


def make_post_hook():
    return r'''

# ===== BUA post-install registration =====
if declare -F bua_register >/dev/null 2>&1; then
    bua_github_release_register || true
fi
# ===== end BUA post-install registration =====
'''


results = []

targets = [
    item
    for item in data["apps"]
    if item.get("source_family") == "github_release_api"
]

print(f"GitHub API targets: {len(targets)}")

for number, item in enumerate(targets, 1):
    app = item["app"]
    owner = item.get("github_owner")
    repo = item.get("github_repo")
    cached = item.get("cached_installer")

    result = {
        "app": app,
        "owner": owner,
        "repo": repo,
        "output": None,
        "syntax_ok": False,
        "registration_ok": False,
        "marker_count": 0,
        "marker": None,
        "error": None,
    }

    print(
        f"[{number:02d}/{len(targets):02d}] "
        f"{app}"
    )

    if not owner or not repo:
        result["error"] = "GitHub owner/repo unresolved"
        results.append(result)
        continue

    if not cached or not Path(cached).is_file():
        result["error"] = "Cached installer missing"
        results.append(result)
        continue

    source = Path(cached).read_text(
        errors="replace"
    )

    if "BUA_REGISTRATION_ONLY" in source:
        result["error"] = (
            "Installer already contains registration support"
        )
        results.append(result)
        continue

    adapter = make_adapter(owner, repo)

    lines = source.splitlines(
        keepends=True
    )

    if lines and lines[0].startswith("#!"):
        converted = (
            lines[0]
            + adapter
            + "".join(lines[1:])
        )
    else:
        converted = (
            "#!/bin/bash\n"
            + adapter
            + source
        )

    converted = (
        converted.rstrip()
        + "\n"
        + make_post_hook()
        + "\n"
    )

    output = safe_path(item)
    output.parent.mkdir(
        parents=True,
        exist_ok=True,
    )

    output.write_text(converted)

    result["output"] = str(output)

    syntax = subprocess.run(
        ["bash", "-n", str(output)],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )

    if syntax.returncode != 0:
        result["error"] = (
            "bash -n failed: "
            + syntax.stdout.strip()
        )
        results.append(result)
        continue

    result["syntax_ok"] = True

    # Test registration mode with the same helper contract used by BUA.
    helper = r'''
bua_register() {
    local app_version="$1"
    local upstream_type="$2"
    local owner="$3"
    local repo="$4"
    local update_method="$5"
    local probe_type="$6"
    local probe_path="$7"
    local probe_key="$8"
    local update_identity="${9:-$app_version}"

    python3 - \
        "$app_version" \
        "$upstream_type" \
        "$owner" \
        "$repo" \
        "$update_method" \
        "$probe_type" \
        "$probe_path" \
        "$probe_key" \
        "$update_identity" <<'PYBUAREG'
import json
import sys

(
    app_version,
    upstream_type,
    owner,
    repo,
    update_method,
    probe_type,
    probe_path,
    probe_key,
    update_identity,
) = sys.argv[1:10]

print(
    "__BUA_REGISTER__="
    + json.dumps(
        {
            "app_version": app_version,
            "update_identity": update_identity,
            "upstream": {
                "type": upstream_type,
                "owner": owner,
                "repo": repo,
            },
            "update_method": update_method,
        },
        separators=(",", ":"),
    )
)
PYBUAREG
}
export -f bua_register
'''

    test_script = (
        helper
        + "\nexport BUA_REGISTRATION_ONLY=1\n"
        + converted
    )

    try:
        test = subprocess.run(
            ["bash"],
            input=test_script,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=45,
        )
    except Exception as exc:
        result["error"] = (
            f"registration execution failed: {exc}"
        )
        results.append(result)
        continue

    markers = [
        line
        for line in test.stdout.splitlines()
        if line.startswith(
            "__BUA_REGISTER__="
        )
    ]

    result["marker_count"] = len(markers)

    if test.returncode != 0:
        result["error"] = (
            f"registration exited {test.returncode}: "
            + test.stdout.strip()
        )
        results.append(result)
        continue

    if len(markers) != 1:
        result["error"] = (
            f"expected 1 marker, got {len(markers)}"
        )
        results.append(result)
        continue

    try:
        payload = json.loads(
            markers[0].split("=", 1)[1]
        )
    except Exception as exc:
        result["error"] = (
            f"invalid marker JSON: {exc}"
        )
        results.append(result)
        continue

    if not payload.get("app_version"):
        result["error"] = (
            "marker has no app_version"
        )
        results.append(result)
        continue

    if not payload.get("update_identity"):
        result["error"] = (
            "marker has no update_identity"
        )
        results.append(result)
        continue

    result["registration_ok"] = True
    result["marker"] = payload

    results.append(result)


REPORT.write_text(
    json.dumps(
        {
            "targets": len(targets),
            "passed": sum(
                1
                for r in results
                if r["syntax_ok"]
                and r["registration_ok"]
            ),
            "failed": sum(
                1
                for r in results
                if not (
                    r["syntax_ok"]
                    and r["registration_ok"]
                )
            ),
            "results": results,
        },
        indent=2,
        sort_keys=True,
    )
)

passed = [
    r for r in results
    if r["syntax_ok"]
    and r["registration_ok"]
]

failed = [
    r for r in results
    if not (
        r["syntax_ok"]
        and r["registration_ok"]
    )
]

print()
print("===== RESULT =====")
print(f"PASSED={len(passed)}")
print(f"FAILED={len(failed)}")
print(f"REPORT={REPORT}")

if failed:
    print()
    print("===== FAILURES =====")

    for r in failed:
        print(
            f'{r["app"]}: {r["error"]}'
        )
