#!/bin/bash

# ===== BUA integration registration adapter =====

bua_integration_identity() {
    python3 - <<'PYBUAINT'
import hashlib
import json
import subprocess
import urllib.request

config = json.loads('{"package_id":"x11vnc","display_version":"rolling","artifacts":[{"kind":"large","url":"https://github.com/batocera-unofficial-addons/batocera-unofficial-addons/raw/refs/heads/main/x11vnc/extra/x11vnc.tar.gz"},{"kind":"small","url":"https://github.com/batocera-unofficial-addons/batocera-unofficial-addons/raw/refs/heads/main/x11vnc/extra/x11vnc"}]}')

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
        "x11vnc" \
        "custom" \
        "" \
        "" \
        "" \
        "$identity"

    exit $?
fi

# ===== end BUA integration registration adapter =====


# === CONFIG ===
TAR_URL="https://github.com/batocera-unofficial-addons/batocera-unofficial-addons/raw/refs/heads/main/x11vnc/extra/x11vnc.tar.gz"
SERVICE_URL="https://github.com/batocera-unofficial-addons/batocera-unofficial-addons/raw/refs/heads/main/x11vnc/extra/x11vnc"
ADDONS_DIR="/userdata/system/add-ons"
SERVICES_DIR="/userdata/system/services"
TAR_NAME="x11vnc.tar.gz"
SERVICE_NAME="x11vnc"
PORT="5900"

# === STEP 1: Create destination directories ===
echo "Creating addon and service directories..."
mkdir -p "$ADDONS_DIR"
mkdir -p "$SERVICES_DIR"

# === STEP 2: Download .tar.gz file ===
echo "Downloading $TAR_NAME..."
curl -L "$TAR_URL" -o "$ADDONS_DIR/$TAR_NAME"

# === STEP 3: Extract the .tar.gz ===
echo "Extracting $TAR_NAME to $ADDONS_DIR..."
tar -xzf "$ADDONS_DIR/$TAR_NAME" -C "$ADDONS_DIR"

# === STEP 4: Set executable permissions for bin/*
echo "Setting executable permissions..."
chmod -R +x "$ADDONS_DIR/x11vnc"

# === STEP 5: Remove .tar.gz ===
echo "Cleaning up $TAR_NAME..."
rm "$ADDONS_DIR/$TAR_NAME"

# === STEP 6: Download the service script ===
echo "Downloading service script..."
curl -L "$SERVICE_URL" -o "$SERVICES_DIR/$SERVICE_NAME"

# === STEP 7: Make the service script executable ===
echo "Making service script executable..."
chmod +x "$SERVICES_DIR/$SERVICE_NAME"

batocera-services enable x11vnc &
batocera-services start x11vnc &>/dev/null &
# === STEP 8: Final success message via dialog ===
dialog --msgbox "x11vnc add-on and service installed successfully!\n\nYou can connect via VNC on port $PORT." 8 55
