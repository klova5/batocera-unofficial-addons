#!/bin/bash

# ===== BUA updater registration adapter =====
bua_github_release_register() {
    local bua_owner='streetpea'
    local bua_repo='chiaki-ng'

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


# Step 1: Detect system architecture
echo "Detecting system architecture..."
arch=$(uname -m)

LATEST=$(curl -s https://api.github.com/repos/streetpea/chiaki-ng/releases/latest | grep '"tag_name"' | cut -d'"' -f4)
if [ "$arch" == "x86_64" ]; then
    echo "Architecture: x86_64 detected."
    appimage_url="https://github.com/streetpea/chiaki-ng/releases/download/${LATEST}/chiaki-ng.AppImage_x86_64"
elif [ "$arch" == "aarch64" ]; then
    echo "Architecture: ARM64 detected."
    appimage_url="https://github.com/streetpea/chiaki-ng/releases/download/${LATEST}/chiaki-ng.AppImage_arm64"
else
    echo "Unsupported architecture: $arch. Exiting."
    exit 1
fi


# Step 2: Prepare directories
echo "Setting up directories..."
mkdir -p /userdata/system/add-ons/chiaki
mkdir -p /userdata/system/add-ons/chiaki/extra
mkdir -p /userdata/system/logs
mkdir -p /userdata/roms/ports/images
mkdir -p /userdata/system/configs/chiaki
DESKTOP_FILE="/usr/share/applications/chiaki.desktop"
PERSISTENT_DESKTOP="/userdata/system/configs/chiaki/chiaki.desktop"
ICON_URL="https://github.com/batocera-unofficial-addons/batocera-unofficial-addons/raw/main/chiaki/extra/icon.png"
INSTALL_DIR="/userdata/system/add-ons/chiaki"
# Step 3: Download the AppImage
echo "Downloading Chiaki AppImage..."
wget -q --show-progress -O /userdata/system/add-ons/chiaki/Chiaki.AppImage "$appimage_url"
if [ $? -ne 0 ]; then
    echo "Failed to download Chiaki AppImage. Exiting."
    exit 1
fi

chmod a+x /userdata/system/add-ons/chiaki/Chiaki.AppImage
echo "Chiaki AppImage downloaded and marked as executable."

echo "Downloading icon..."
wget --show-progress -qO "${INSTALL_DIR}/extra/icon.png" "$ICON_URL"

# Step 4: Create the Chiaki launch script
echo "Creating Chiaki launch script in Ports..."
cat << 'EOF' > /userdata/roms/ports/Chiaki.sh
#!/bin/bash

# Environment setup
export $(cat /proc/1/environ | tr '\0' '\n')
export DISPLAY=:0.0
export QTWEBENGINE_DISABLE_SANDBOX=1

# Directories and file paths
app_dir="/userdata/system/add-ons/chiaki"
app_image="${app_dir}/Chiaki.AppImage"
log_dir="/userdata/system/logs"
log_file="${log_dir}/chiaki.log"

# Ensure log directory exists
mkdir -p "${log_dir}"

# Append all output to the log file
exec &> >(tee -a "$log_file")
echo "$(date): Launching Chiaki"

# Launch Chiaki AppImage
if [ -x "${app_image}" ]; then
    cd "${app_dir}"
    ./Chiaki.AppImage > "${log_file}" 2>&1
    echo
fi
EOF

chmod +x /userdata/roms/ports/Chiaki.sh

# Create persistent desktop entry
echo "Creating persistent desktop entry for Chiaki..."
cat <<EOF > "$PERSISTENT_DESKTOP"
[Desktop Entry]
Version=1.0
Type=Application
Name=Chiaki-NG
Exec=/userdata/roms/ports/Chiaki.sh
Icon=/userdata/system/add-ons/chiaki/extra/icon.png
Terminal=false
Categories=Game;batocera.linux;
EOF

chmod +x "$PERSISTENT_DESKTOP"

cp "$PERSISTENT_DESKTOP" "$DESKTOP_FILE"
chmod +x "$DESKTOP_FILE"

# Ensure the desktop entry is always restored to /usr/share/applications
echo "Ensuring Chiaki desktop entry is restored at startup..."
cat <<EOF > "/userdata/system/configs/chiaki/restore_desktop_entry.sh"
#!/bin/bash
# Restore Chiaki desktop entry
if [ ! -f "$DESKTOP_FILE" ]; then
    echo "Restoring Chiaki desktop entry..."
    cp "$PERSISTENT_DESKTOP" "$DESKTOP_FILE"
    chmod +x "$DESKTOP_FILE"
    echo "Chiaki desktop entry restored."
else
    echo "Chiaki desktop entry already exists."
fi
EOF
chmod +x "/userdata/system/configs/chiaki/restore_desktop_entry.sh"

# Add to startup script
custom_startup="/userdata/system/custom.sh"
if ! grep -q "/userdata/system/configs/chiaki/restore_desktop_entry.sh" "$custom_startup"; then
    echo "Adding Chiaki restore script to startup..."
    echo "bash "/userdata/system/configs/chiaki/restore_desktop_entry.sh" &" >> "$custom_startup"
fi
chmod +x "$custom_startup"

# Step 5: Add Chiaki to Ports menu
if ! command -v xmlstarlet &> /dev/null; then
    echo "Error: xmlstarlet is not installed. Install it and re-run the script."
    exit 1
fi

echo "Adding Chiaki to Ports menu..."
curl -L -o /userdata/roms/ports/images/chiakilogo.png https://github.com/batocera-unofficial-addons/batocera-unofficial-addons/raw/main/chiaki/extra/chiakilogo.png
xmlstarlet ed -s "/gameList" -t elem -n "game" -v "" \
  -s "/gameList/game[last()]" -t elem -n "path" -v "./Chiaki.sh" \
  -s "/gameList/game[last()]" -t elem -n "name" -v "Chiaki" \
  -s "/gameList/game[last()]" -t elem -n "image" -v "./images/chiakilogo.png" \
  /userdata/roms/ports/gamelist.xml > /userdata/roms/ports/gamelist.xml.tmp && mv /userdata/roms/ports/gamelist.xml.tmp /userdata/roms/ports/gamelist.xml

# Step 6: Refresh the Ports menu
echo "Refreshing Ports menu..."
curl http://127.0.0.1:1234/reloadgames

echo
echo "Installation complete! You can now launch Chiaki from the Ports menu."


# ===== BUA post-install registration =====
if declare -F bua_register >/dev/null 2>&1; then
    bua_github_release_register || true
fi
# ===== end BUA post-install registration =====

