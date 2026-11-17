#!/bin/bash

# ===== BUA integration registration adapter =====

bua_integration_identity() {
    python3 - <<'PYBUAINT'
import hashlib
import json
import subprocess
import urllib.request

config = json.loads('{"package_id":"gamescope","display_version":"rolling","artifacts":[{"kind":"large","url":"https://github.com/batocera-unofficial-addons/batocera-unofficial-addons/raw/refs/heads/main/gamescope/extra/gamescope.tar.gz"}]}')

def large_metadata(url):
    result = subprocess.run(
        ["curl", "-fsSIL", url],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=30,
    )

    if result.returncode != 0:
        raise SystemExit(
            "Unable to inspect integration artifact: "
            + url
        )

    etag = ""
    modified = ""
    length = ""

    for line in result.stdout.splitlines():
        lower = line.lower()

        if lower.startswith("etag:"):
            etag = line.split(":", 1)[1].strip()
        elif lower.startswith("last-modified:"):
            modified = line.split(":", 1)[1].strip()
        elif lower.startswith("content-length:"):
            length = line.split(":", 1)[1].strip()

    return {
        "url": url,
        "etag": etag,
        "last_modified": modified,
        "content_length": length,
    }

def small_hash(url):
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
        data = response.read()

    return {
        "url": url,
        "sha256": hashlib.sha256(
            data
        ).hexdigest(),
    }

artifacts = []

for item in config["artifacts"]:
    if item.get("kind") == "small":
        artifacts.append(
            small_hash(item["url"])
        )
    else:
        artifacts.append(
            large_metadata(item["url"])
        )

payload = {
    "package_id": config["package_id"],
    "display_version": config["display_version"],
    "artifacts": artifacts,
}

serialized = json.dumps(
    payload,
    sort_keys=True,
    separators=(",", ":"),
).encode("utf-8")

digest = hashlib.sha256(
    serialized
).hexdigest()

print(config["display_version"])
print(
    "integration:"
    + config["package_id"]
    + ":"
    + digest
)
PYBUAINT
}

if [[ "${BUA_REGISTRATION_ONLY:-0}" == "1" ]]; then
    if ! declare -F bua_register >/dev/null 2>&1; then
        echo "BUA registration helper unavailable." >&2
        exit 1
    fi

    values="$(
        bua_integration_identity
    )" || exit 1

    version="$(
        printf '%s\n' "$values" |
            sed -n '1p'
    )"

    identity="$(
        printf '%s\n' "$values" |
            sed -n '2p'
    )"

    bua_register \
        "$version" \
        "integration_asset" \
        "BUA" \
        "gamescope" \
        "custom" \
        "" \
        "" \
        "" \
        "$identity"

    exit $?
fi

# ===== end BUA integration registration adapter =====

#=======================================================================
# Special thanks to Redemp/Rion and Spirit(RGS) for providing Gamescope
#=======================================================================

set -e

GAMESCOPE_URL="https://github.com/batocera-unofficial-addons/batocera-unofficial-addons/raw/refs/heads/main/gamescope/extra/gamescope.tar.gz"
DEST_DIR="/userdata/system"
TAR_PATH="${DEST_DIR}/gamescope.tar.gz"
EXTRACT_DIR="${DEST_DIR}/gamescope"

echo "== Downloading gamescope.tar.gz =="
mkdir -p "$DEST_DIR"

wget -q --show-progress -c -O "$TAR_PATH" "$GAMESCOPE_URL"

echo "== Removing old extracted directory =="
rm -rf "$EXTRACT_DIR"

echo "== Extracting archive =="
tar -xzf "$TAR_PATH" -C "$DEST_DIR"

INSTALL_SCRIPT="${EXTRACT_DIR}/install_gamescope_v42.sh"
UNINSTALL_SCRIPT="${EXTRACT_DIR}/uninstall_gamescope_v42.sh"

echo "== Setting executable permissions =="
chmod +x "$INSTALL_SCRIPT"
chmod +x "$UNINSTALL_SCRIPT"

echo "== Running installer =="
bash "$INSTALL_SCRIPT"

echo "== Gamescope v42 Installed Successfully =="
