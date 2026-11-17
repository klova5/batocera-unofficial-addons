#!/bin/bash

# ===== BUA updater registration adapter =====
bua_github_release_register() {
    local bua_owner='pkgforge'
    local bua_repo='soar'

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
    f"{owner}/{repo}/releases/latest"
)

req = urllib.request.Request(
    url,
    headers={
        "User-Agent": "BUA-Updater",
        "Accept": "application/vnd.github+json",
        "Cache-Control": "no-cache",
    },
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
    assets.append({
        "id": asset.get("id"),
        "name": asset.get("name"),
        "size": asset.get("size"),
        "updated_at": asset.get("updated_at"),
    })

identity_payload = {
    "release_id": release.get("id"),
    "release_updated_at": release.get("updated_at"),
    "assets": sorted(
        assets,
        key=lambda a: (
            str(a.get("name") or ""),
            str(a.get("id") or ""),
        ),
    ),
}

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
}

if [[ "${BUA_REGISTRATION_ONLY:-0}" == "1" ]]; then
    if ! declare -F bua_register >/dev/null 2>&1; then
        echo "BUA registration helper is unavailable." >&2
        exit 1
    fi

    bua_github_release_register
    exit $?
fi
# ===== end BUA updater registration adapter =====


# Detect architecture
ARCH=$(uname -m)
case "$ARCH" in
    x86_64)
        SOAR_BINARY="soar-x86_64-linux"
        CONFIG_FILE_URL="https://raw.githubusercontent.com/batocera-unofficial-addons/batocera-unofficial-addons/main/soar/extra/config.toml"
        ;;
    aarch64)
        SOAR_BINARY="soar-aarch64-linux"
        CONFIG_FILE_URL="https://raw.githubusercontent.com/batocera-unofficial-addons/batocera-unofficial-addons/main/soar/extra/arm64_config.toml"
        ;;
    *)
        echo "Unsupported architecture: $ARCH"
        exit 1
        ;;
esac

# Directories
SOAR_BIN_DIR="/userdata/system/add-ons/soar/bin"
SOAR_CONFIG_DIR="/userdata/system/.config/soar"
SOAR_BINARY_PATH="$SOAR_BIN_DIR/soar"

# Ensure directories exist
mkdir -p "$SOAR_BIN_DIR"
mkdir -p "$SOAR_CONFIG_DIR"

# Get latest release tag from GitHub API
LATEST_TAG=$(curl -s https://api.github.com/repos/pkgforge/soar/releases/latest | grep '"tag_name":' | cut -d '"' -f 4)
if [ -z "$LATEST_TAG" ]; then
    echo "Failed to fetch the latest Soar release tag."
    exit 1
fi

# Build download URL
SOAR_URL="https://github.com/pkgforge/soar/releases/download/${LATEST_TAG}/${SOAR_BINARY}"

# Download the Soar binary
curl -Lso "$SOAR_BINARY_PATH" "$SOAR_URL"
chmod +x "$SOAR_BINARY_PATH"

# Download the appropriate config file
curl -Lso "$SOAR_CONFIG_DIR/config.toml" "$CONFIG_FILE_URL"

echo "Soar setup completed for $ARCH!"


# ===== BUA post-install registration =====
if declare -F bua_register >/dev/null 2>&1; then
    bua_github_release_register || true
fi
# ===== end BUA post-install registration =====

