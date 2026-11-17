#!/bin/bash

# ===== BUA integration registration adapter =====

bua_integration_identity() {
    python3 - <<'PYBUAINT'
import hashlib
import json
import subprocess
import urllib.request

config = json.loads('{"package_id":"dark-mode","display_version":"rolling","artifacts":[{"kind":"large","url":"https://github.com/batocera-unofficial-addons/batocera-unofficial-addons/raw/refs/heads/main/dark/extra/Adwaita-dark.zip"},{"kind":"small","url":"https://github.com/batocera-unofficial-addons/batocera-unofficial-addons/raw/refs/heads/main/dark/extra/dark_mode"}]}')

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
        "dark-mode" \
        "custom" \
        "" \
        "" \
        "" \
        "$identity"

    exit $?
fi

# ===== end BUA integration registration adapter =====


echo "Preparing dark mode install..."

# Define paths
DEST_DIR="/userdata/system/add-ons/darkmode"
SERVICE_DIR="/userdata/system/services"
ZIP_URL="https://github.com/batocera-unofficial-addons/batocera-unofficial-addons/raw/refs/heads/main/dark/extra/Adwaita-dark.zip"
SERVICE_URL="https://github.com/batocera-unofficial-addons/batocera-unofficial-addons/raw/refs/heads/main/dark/extra/dark_mode"
ZIP_FILE="${DEST_DIR}/Adwaita-dark.zip"
SERVICE_FILE="${SERVICE_DIR}/dark_mode"

# Create destination folders
mkdir -p "$DEST_DIR" "$SERVICE_DIR"

# Download and extract theme
echo "Downloading Adwaita-dark.zip..."
wget -q -O "$ZIP_FILE" "$ZIP_URL"

if [ -f "$ZIP_FILE" ]; then
    echo "Extracting theme..."
    unzip -oq "$ZIP_FILE" -d "$DEST_DIR"
    rm -f "$ZIP_FILE"
else
    echo "Error: Failed to download Adwaita-dark.zip"
    exit 1
fi

# Download service script
echo "Downloading dark_mode service..."
wget -q -O "$SERVICE_FILE" "$SERVICE_URL"
chmod +x "$SERVICE_FILE"

echo "Dark mode install complete. You can toggle dark mode on and off via the services menu."
