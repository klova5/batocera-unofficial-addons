#!/bin/bash

# ===== BUA integration registration adapter =====

bua_integration_identity() {
    python3 - <<'PYBUAINT'
import hashlib
import json
import subprocess
import urllib.request

config = json.loads('{"package_id":"nvidia-patcher","display_version":"rolling","artifacts":[{"kind":"small","url":"https://raw.githubusercontent.com/batocera-unofficial-addons/batocera-unofficial-addons/main/nvidiapatch/patches.sh"}]}')

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
        "nvidia-patcher" \
        "custom" \
        "" \
        "" \
        "" \
        "$identity"

    exit $?
fi

# ===== end BUA integration registration adapter =====


#!/bin/bash

# Halt on error
set -euo pipefail

# Create a temporary directory for downloading the scripts
TEMP_DIR=$(mktemp -d)

# Function to clean up the temporary files
cleanup() {
    echo "Cleaning up..."
    rm -rf "$TEMP_DIR"
}

# Trap to clean up in case of exit or error
trap cleanup EXIT

detect_driver_version() {
    local version=""

    # Try to parse the driver version from the Nvidia log (covers "Production" and other variants)
    if [[ -f /userdata/system/logs/nvidia.log ]]; then
        version=$(
            sed -n 's/.*Using NVIDIA .*driver - \([0-9][0-9.]*\).*/\1/p' /userdata/system/logs/nvidia.log \
            | head -n1 \
            | tr -d '[:space:]'
        )
    fi

    # Fallback to nvidia-smi if the log did not yield a version
    if [[ -z "$version" ]] && command -v nvidia-smi >/dev/null 2>&1; then
        version=$(
            nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null \
            | head -n1 \
            | tr -d '[:space:]' || true
        )
    fi

    echo "$version"
}

# Detect Nvidia GPU and apply patches
if lspci | grep -i "nvidia" > /dev/null; then
    echo "Nvidia GPU detected. Applying patches..."
    
    driver_version=$(detect_driver_version)
    
    # Check if driver version was found
    if [[ -z "$driver_version" ]]; then
        echo "Error: Could not detect Nvidia driver version."
        exit 1
    fi

    echo "Detected Nvidia driver version: $driver_version"
    
    # Download the patch scripts to the temporary directory
    curl -LsS "https://github.com/batocera-unofficial-addons/batocera-unofficial-addons/raw/main/nvidiapatch/patches.sh" -o "$TEMP_DIR/nvidia_patch.sh"

    # Run the patch scripts with the detected driver version
    bash "$TEMP_DIR/nvidia_patch.sh" "$driver_version"
    
elif lspci | grep -i "amd" > /dev/null; then
    echo "AMD GPU detected. Skipping Nvidia patches."
else
    echo "No supported GPU detected. Skipping patches."
fi

# Cleanup the temporary files (this will be done automatically by trap)
