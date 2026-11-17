#!/usr/bin/env python3

import json
import re
import subprocess
from pathlib import Path

ROOT = Path("/userdata/system/add-ons/bua/updater")

MANIFEST = (
    ROOT
    / "catalog/global/global-update-manifest.json"
)

MAP = (
    ROOT
    / "catalog/global/trusted-github-parent-map.json"
)

OUTROOT = (
    ROOT
    / "converted/trusted-github-parents"
)

REPORT = (
    ROOT
    / "catalog/global/"
      "trusted-github-parent-adapter-report.json"
)

OUTROOT.mkdir(
    parents=True,
    exist_ok=True,
)

with MANIFEST.open() as f:
    manifest = json.load(f)

with MAP.open() as f:
    trusted = json.load(f)

by_app = {
    item["app"]: item
    for item in manifest["apps"]
}


def output_path(item):
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


POST_HOOK = r'''

# ===== BUA post-install registration =====
if declare -F bua_register >/dev/null 2>&1; then
    bua_github_release_register || true
fi
# ===== end BUA post-install registration =====
'''


HELPER = r'''
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
                "repo": repo
            },
            "update_method": update_method
        },
        separators=(",", ":")
    )
)
PYBUAREG
}
export -f bua_register
'''


results = []

for index, (app, source) in enumerate(
    trusted.items(),
    1,
):
    print(
        f"[{index:02d}/{len(trusted):02d}] "
        f"{app}"
    )

    item = by_app.get(app)

    result = {
        "app": app,
        "owner": source["owner"],
        "repo": source["repo"],
        "output": None,
        "syntax_ok": False,
        "registration_ok": False,
        "marker": None,
        "error": None,
    }

    if not item:
        result["error"] = (
            "app not present in manifest"
        )
        results.append(result)
        continue

    cached = item.get(
        "cached_installer"
    )

    if (
        not cached
        or not Path(cached).is_file()
    ):
        result["error"] = (
            "cached installer missing"
        )
        results.append(result)
        continue

    source_text = Path(cached).read_text(
        errors="replace"
    )

    adapter = make_adapter(
        source["owner"],
        source["repo"],
    )

    lines = source_text.splitlines(
        keepends=True
    )

    if (
        lines
        and lines[0].startswith("#!")
    ):
        converted = (
            lines[0]
            + adapter
            + "".join(lines[1:])
        )
    else:
        converted = (
            "#!/bin/bash\n"
            + adapter
            + source_text
        )

    converted = (
        converted.rstrip()
        + "\n"
        + POST_HOOK
        + "\n"
    )

    out = output_path(item)

    out.parent.mkdir(
        parents=True,
        exist_ok=True,
    )

    out.write_text(converted)

    result["output"] = str(out)

    syntax = subprocess.run(
        ["bash", "-n", str(out)],
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

    test_script = (
        HELPER
        + "\n"
        + "export BUA_REGISTRATION_ONLY=1\n"
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
        result["error"] = str(exc)
        results.append(result)
        continue

    markers = [
        line
        for line in test.stdout.splitlines()
        if line.startswith(
            "__BUA_REGISTER__="
        )
    ]

    if test.returncode != 0:
        result["error"] = (
            f"registration exited "
            f"{test.returncode}: "
            + test.stdout.strip()
        )
        results.append(result)
        continue

    if len(markers) != 1:
        result["error"] = (
            f"expected 1 marker, "
            f"got {len(markers)}"
        )
        results.append(result)
        continue

    payload = json.loads(
        markers[0].split("=", 1)[1]
    )

    if not payload.get("app_version"):
        result["error"] = (
            "missing app_version"
        )
        results.append(result)
        continue

    if not payload.get("update_identity"):
        result["error"] = (
            "missing update_identity"
        )
        results.append(result)
        continue

    result["registration_ok"] = True
    result["marker"] = payload

    results.append(result)


passed = [
    r for r in results
    if (
        r["syntax_ok"]
        and r["registration_ok"]
    )
]

failed = [
    r for r in results
    if not (
        r["syntax_ok"]
        and r["registration_ok"]
    )
]

REPORT.write_text(
    json.dumps(
        {
            "targets": len(results),
            "passed": len(passed),
            "failed": len(failed),
            "results": results,
        },
        indent=2,
        sort_keys=True,
    )
)

print()
print("===== RESULT =====")
print(f"PASSED={len(passed)}")
print(f"FAILED={len(failed)}")
print(f"REPORT={REPORT}")

if failed:
    print()
    for r in failed:
        print(
            f'{r["app"]}: '
            f'{r["error"]}'
        )
