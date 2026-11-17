#!/usr/bin/env python3

import json
import re
import subprocess
from pathlib import Path

ROOT = Path("/userdata/system/add-ons/bua/updater")

MANIFEST = ROOT / "catalog/global/global-update-manifest.json"

TRUSTED = (
    ROOT
    / "catalog/global/trusted-github-parent-map.json"
)

OUTROOT = (
    ROOT
    / "converted/github-web-parents"
)

REPORT = (
    ROOT
    / "catalog/global/github-web-parent-adapter-report.json"
)

OUTROOT.mkdir(
    parents=True,
    exist_ok=True,
)

with MANIFEST.open() as f:
    manifest = json.load(f)

with TRUSTED.open() as f:
    trusted = json.load(f)

by_app = {
    item["app"]: item
    for item in manifest["apps"]
}


# Start with the 22 original direct GitHub API apps.
targets = {}

for item in manifest["apps"]:
    if item.get("source_family") == "github_release_api":
        owner = item.get("github_owner")
        repo = item.get("github_repo")

        if owner and repo:
            targets[item["app"]] = {
                "owner": owner,
                "repo": repo,
                "source_group": "original_github_api",
            }


# Add/override the 11 manually verified parent mappings.
for app, source in trusted.items():
    targets[app] = {
        "owner": source["owner"],
        "repo": source["repo"],
        "source_group": "trusted_parent",
    }


def output_path(item):
    installer_path = item.get("installer_path")

    if installer_path:
        return OUTROOT / installer_path

    slug = re.sub(
        r"[^A-Za-z0-9._-]+",
        "_",
        item["app"],
    ).strip("_")

    return OUTROOT / f"{slug}.sh"


def make_adapter(owner, repo):
    return rf'''
# ===== BUA GitHub web registration adapter =====
bua_github_web_register() {{
    local bua_owner={owner!r}
    local bua_repo={repo!r}

    local bua_values

    bua_values=$(
        python3 - "$bua_owner" "$bua_repo" <<'PYBUAGH'
import hashlib
import html
import json
import re
import sys
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

owner, repo = sys.argv[1:3]

UA = "Mozilla/5.0 BUA-Updater"


def request(url):
    req = urllib.request.Request(
        url,
        headers={{
            "User-Agent": UA,
            "Cache-Control": "no-cache",
        }},
    )

    with urllib.request.urlopen(
        req,
        timeout=25,
    ) as response:
        return (
            response.geturl(),
            response.read(),
        )


def latest_tag():
    latest_url = (
        f"https://github.com/{{owner}}/{{repo}}/"
        "releases/latest"
    )

    try:
        final_url, _ = request(latest_url)

        match = re.search(
            r"/releases/tag/([^/?#]+)",
            final_url,
        )

        if match:
            return urllib.parse.unquote(
                match.group(1)
            )

    except Exception:
        pass

    # Nightly/prerelease fallback.
    atom_url = (
        f"https://github.com/{{owner}}/{{repo}}/"
        "releases.atom"
    )

    _, body = request(atom_url)

    root = ET.fromstring(body)

    ns = {{
        "atom": "http://www.w3.org/2005/Atom",
    }}

    entries = root.findall(
        "atom:entry",
        ns,
    )

    for entry in entries:
        link = entry.find(
            "atom:link",
            ns,
        )

        if link is None:
            continue

        href = link.attrib.get(
            "href",
            "",
        )

        match = re.search(
            r"/releases/tag/([^/?#]+)",
            href,
        )

        if match:
            return urllib.parse.unquote(
                match.group(1)
            )

    raise RuntimeError(
        "Unable to determine GitHub release tag"
    )


def asset_fingerprint(tag):
    encoded_tag = urllib.parse.quote(
        tag,
        safe="",
    )

    url = (
        f"https://github.com/{{owner}}/{{repo}}/"
        f"releases/expanded_assets/{{encoded_tag}}"
    )

    _, body = request(url)

    text = html.unescape(
        body.decode(
            "utf-8",
            errors="replace",
        )
    )

    href_pattern = re.compile(
        rf'href="(/'
        rf'{{re.escape(owner)}}/'
        rf'{{re.escape(repo)}}/'
        r'releases/download/[^"]+)"',
        re.I,
    )

    hrefs = sorted(
        set(
            href_pattern.findall(text)
        )
    )

    datetimes = sorted(
        set(
            re.findall(
                r'datetime="([^"]+)"',
                text,
                re.I,
            )
        )
    )

    sizes = sorted(
        set(
            re.findall(
                r'([0-9]+(?:\.[0-9]+)?\s*'
                r'(?:Bytes|KB|MB|GB|KiB|MiB|GiB))',
                text,
                re.I,
            )
        )
    )

    payload = {{
        "owner": owner,
        "repo": repo,
        "tag": tag,
        "assets": hrefs,
        "datetimes": datetimes,
        "sizes": sizes,
    }}

    encoded = json.dumps(
        payload,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")

    return hashlib.sha256(
        encoded
    ).hexdigest()


tag = latest_tag()

digest = asset_fingerprint(
    tag
)

identity = (
    "github-web:"
    + tag
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
        echo "BUA registration helper unavailable." >&2
        exit 1
    fi

    bua_github_web_register
    exit $?
fi
# ===== end BUA GitHub web registration adapter =====

'''


POST_HOOK = r'''

# ===== BUA post-install registration =====
if declare -F bua_register >/dev/null 2>&1; then
    bua_github_web_register || true
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


results = []

print(
    f"Unified GitHub web targets: "
    f"{len(targets)}"
)
print()

for index, app in enumerate(
    sorted(targets),
    1,
):
    source = targets[app]
    item = by_app.get(app)

    result = {
        "app": app,
        "owner": source["owner"],
        "repo": source["repo"],
        "source_group": source["source_group"],
        "output": None,
        "syntax_ok": False,
        "registration_ok": False,
        "marker": None,
        "error": None,
    }

    print(
        f"[{index:02d}/{len(targets):02d}] "
        f"{app}"
    )

    if not item:
        result["error"] = "app missing from manifest"
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

    original = Path(cached).read_text(
        errors="replace"
    )

    adapter = make_adapter(
        source["owner"],
        source["repo"],
    )

    lines = original.splitlines(
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
            + original
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
            timeout=60,
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

    try:
        payload = json.loads(
            markers[0].split(
                "=",
                1,
            )[1]
        )
    except Exception as exc:
        result["error"] = (
            f"invalid marker JSON: {exc}"
        )
        results.append(result)
        continue

    if not payload.get("app_version"):
        result["error"] = (
            "missing app_version"
        )
        results.append(result)
        continue

    identity = payload.get(
        "update_identity",
        "",
    )

    if not identity.startswith(
        "github-web:"
    ):
        result["error"] = (
            "invalid github-web update_identity"
        )
        results.append(result)
        continue

    result["registration_ok"] = True
    result["marker"] = payload

    results.append(result)


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
    print("===== FAILURES =====")

    for r in failed:
        print(
            f'{r["app"]}: '
            f'{r["error"]}'
        )
