#!/bin/bash

# ===== BUA updater registration adapter =====
bua_github_release_register() {
    local bua_owner='raspberrypi'
    local bua_repo='rpi-imager'

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


# Variables to update for different apps
APP_NAME="rpi"
DISPLAY_NAME="Raspberry Pi Imager"
REPO="raspberrypi/rpi-imager"
AMD_SUFFIX="desktop-x86_64.AppImage"
ARM_SUFFIX="desktop-aarch64.AppImage"
ICON_URL="https://raw.githubusercontent.com/iiiypuk/rpi-icon/master/raspberry-pi-logo_resized_256.png"
# Directories
ADDONS_DIR="/userdata/system/add-ons"
CONFIGS_DIR="/userdata/system/configs"
DESKTOP_DIR="/usr/share/applications"
CUSTOM_SCRIPT="/userdata/system/custom.sh"
APP_CONFIG_DIR="${CONFIGS_DIR}/${APP_NAME,,}"
PERSISTENT_DESKTOP="${APP_CONFIG_DIR}/${APP_NAME,,}.desktop"
DESKTOP_FILE="${DESKTOP_DIR}/${APP_NAME,,}.desktop"

# Ensure directories exist
echo "Creating necessary directories..."
mkdir -p "$APP_CONFIG_DIR" "$ADDONS_DIR/${APP_NAME,,}"
mkdir -p "$ADDONS_DIR/${APP_NAME,,}/extra"

# Step 1: Detect system architecture and fetch the latest release
echo "Detecting system architecture..."
arch=$(uname -m)

if [ "$arch" == "x86_64" ]; then
    echo "Architecture: x86_64 detected."
    appimage_url=$(curl -s https://api.github.com/repos/$REPO/releases/latest | jq -r ".assets[]? | select(.name | endswith(\"$AMD_SUFFIX\")) | .browser_download_url" | head -n1)
elif [ "$arch" == "aarch64" ]; then
    echo "Architecture: arm64 detected."
    if [ -n "$ARM_SUFFIX" ]; then
        appimage_url=$(curl -s https://api.github.com/repos/$REPO/releases/latest | jq -r ".assets[]? | select(.name | endswith(\"$ARM_SUFFIX\")) | .browser_download_url" | head -n1)
    else
        echo "No ARM64 AppImage suffix provided. Skipping download. Exiting."
        exit 1
    fi
else
    echo "Unsupported architecture: $arch. Exiting."
    exit 1
fi

if [ -z "$appimage_url" ]; then
    echo "No suitable AppImage found for architecture: $arch. Exiting."
    exit 1
fi

# ==========================================================

# Step 2: Download the AppImage
echo "Downloading $APP_NAME AppImage from $appimage_url..."
wget -q --show-progress -O "$ADDONS_DIR/${APP_NAME,,}/${APP_NAME,,}.AppImage" "$appimage_url"

if [ $? -ne 0 ]; then
    echo "Failed to download $APP_NAME AppImage."
    exit 1
fi

chmod a+x "$ADDONS_DIR/${APP_NAME,,}/${APP_NAME,,}.AppImage"
echo "$APP_NAME AppImage downloaded and marked as executable."

# Step 2.5: Download the application icon
echo "Downloading $APP_NAME icon..."
wget -q --show-progress -O "$ADDONS_DIR/${APP_NAME,,}/extra/${APP_NAME,,}-icon.png" "$ICON_URL"

if [ $? -ne 0 ]; then
    echo "Failed to download $APP_NAME icon."
    exit 1
fi

# Step 3: Create persistent desktop entry
echo "Creating persistent desktop entry for $APP_NAME..."
cat <<EOF > "$PERSISTENT_DESKTOP"
[Desktop Entry]
Version=1.0
Type=Application
Name=$DISPLAY_NAME
Exec=$ADDONS_DIR/${APP_NAME,,}/${APP_NAME,,}.AppImage
Icon=$ADDONS_DIR/${APP_NAME,,}/extra/${APP_NAME,,}-icon.png
Terminal=false
Categories=Game;batocera.linux;
EOF

chmod +x "$PERSISTENT_DESKTOP"

cp "$PERSISTENT_DESKTOP" "$DESKTOP_FILE"
chmod +x "$DESKTOP_FILE"

# Ensure the desktop entry is always restored to /usr/share/applications
echo "Ensuring $APP_NAME desktop entry is restored at startup..."
cat <<EOF > "${APP_CONFIG_DIR}/restore_desktop_entry.sh"
#!/bin/bash
# Restore $APP_NAME desktop entry
if [ ! -f "$DESKTOP_FILE" ]; then
    echo "Restoring $APP_NAME desktop entry..."
    cp "$PERSISTENT_DESKTOP" "$DESKTOP_FILE"
    chmod +x "$DESKTOP_FILE"
    echo "$APP_NAME desktop entry restored."
else
    echo "$APP_NAME desktop entry already exists."
fi
EOF
chmod +x "${APP_CONFIG_DIR}/restore_desktop_entry.sh"

# Add to startup (Option C: create or append safely)
echo "Adding desktop entry restore script to startup..."

if [ -f "$CUSTOM_SCRIPT" ]; then
    echo "Existing custom.sh found, appending restore call if not already present..."
    # Only append if our restore call isn't already there
    if ! grep -q "${APP_CONFIG_DIR}/restore_desktop_entry.sh" "$CUSTOM_SCRIPT"; then
        cat <<EOF >> "$CUSTOM_SCRIPT"

# Restore $APP_NAME desktop entry at startup
bash "${APP_CONFIG_DIR}/restore_desktop_entry.sh" &
EOF
    else
        echo "Restore call already present in custom.sh, skipping append."
    fi
else
    echo "No existing custom.sh, creating new one..."
    cat <<EOF > "$CUSTOM_SCRIPT"
#!/bin/bash
# Restore $APP_NAME desktop entry at startup
bash "${APP_CONFIG_DIR}/restore_desktop_entry.sh" &
EOF
fi

chmod +x "$CUSTOM_SCRIPT"

echo "$APP_NAME desktop entry creation complete."


# ===== BUA post-install registration =====
if declare -F bua_register >/dev/null 2>&1; then
    bua_github_release_register || true
fi
# ===== end BUA post-install registration =====

