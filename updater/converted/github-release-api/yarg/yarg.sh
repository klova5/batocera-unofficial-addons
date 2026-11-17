#!/bin/bash

# ===== BUA updater registration adapter =====
bua_github_release_register() {
    local bua_owner='YARC-Official'
    local bua_repo='YARC-Launcher'

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


APP_NAME="YARG"
INSTALL_DIR="/userdata/system/add-ons/yarg"
LOGS_DIR="/userdata/system/logs"
PORTS_DIR="/userdata/roms/ports"
GAME_LIST="/userdata/roms/ports/gamelist.xml"
LOGO_PATH="${PORTS_DIR}/images/yarg-logo.png"
PORT_SCRIPT="${PORTS_DIR}/${APP_NAME}.sh"
DESKTOP_FILE="/usr/share/applications/YARC-Launcher.desktop"
PERSISTENT_DESKTOP="/userdata/system/configs/yarg/YARC-Launcher.desktop"
ICON_URL="https://static.wikitide.net/yargwiki/3/3c/YARG_Icon.png"

# Step 1: Detect architecture
echo "Detecting system architecture..."
arch=$(uname -m)
if [ "$arch" != "x86_64" ]; then
    echo "Unsupported architecture: $arch. Exiting."
    exit 1
fi

# Step 2: Fetch latest YARC Launcher release
echo "Fetching latest YARC Launcher release..."
LATEST=$(curl -s https://api.github.com/repos/YARC-Official/YARC-Launcher/releases/latest | grep '"tag_name"' | cut -d'"' -f4)
if [ -z "$LATEST" ]; then
    echo "Failed to fetch latest release. Exiting."
    exit 1
fi
LAUNCHER_URL="https://github.com/YARC-Official/YARC-Launcher/releases/download/${LATEST}/YARC.Launcher_${LATEST#v}_amd64.AppImage"
echo "Latest version: $LATEST"

# Step 3: Download launcher AppImage
echo "Downloading YARC Launcher..."
mkdir -p "$INSTALL_DIR" "$LOGS_DIR"
wget -q --show-progress -O "${INSTALL_DIR}/yarg-launcher.AppImage" "$LAUNCHER_URL"
if [ $? -ne 0 ]; then
    echo "Failed to download YARC Launcher. Exiting."
    exit 1
fi
chmod a+x "${INSTALL_DIR}/yarg-launcher.AppImage"
echo "YARC Launcher downloaded and marked as executable."

# Step 4: Create desktop entry for F1 Applications
echo "Creating desktop entry for YARC Launcher..."
mkdir -p "/userdata/system/configs/yarg" "${INSTALL_DIR}/extra"

echo "Downloading icon..."
wget -q --show-progress -O "${INSTALL_DIR}/extra/icon.png" "$ICON_URL"

cat > "${INSTALL_DIR}/yarg-launcher.sh" << 'EOF'
#!/bin/bash
export DISPLAY=:0.0
export HOME=/userdata/system/add-ons/yarg
cd /userdata/system/add-ons/yarg
./yarg-launcher.AppImage
EOF
chmod +x "${INSTALL_DIR}/yarg-launcher.sh"

cat > "$PERSISTENT_DESKTOP" << EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=YARC Launcher
Exec=/userdata/system/add-ons/yarg/yarg-launcher.sh
Icon=/userdata/system/add-ons/yarg/extra/icon.png
Terminal=false
Categories=Game;batocera.linux;
EOF
chmod +x "$PERSISTENT_DESKTOP"
cp "$PERSISTENT_DESKTOP" "$DESKTOP_FILE"
chmod +x "$DESKTOP_FILE"

# Restore desktop entry on boot
cat > "/userdata/system/configs/yarg/restore_desktop_entry.sh" << 'EOF'
#!/bin/bash
if [ ! -f "/usr/share/applications/YARC-Launcher.desktop" ]; then
    cp "/userdata/system/configs/yarg/YARC-Launcher.desktop" "/usr/share/applications/YARC-Launcher.desktop"
    chmod +x "/usr/share/applications/YARC-Launcher.desktop"
fi
EOF
chmod +x "/userdata/system/configs/yarg/restore_desktop_entry.sh"

CUSTOM_SH="/userdata/system/custom.sh"
if ! grep -q "/userdata/system/configs/yarg/restore_desktop_entry.sh" "$CUSTOM_SH" 2>/dev/null; then
    echo 'bash "/userdata/system/configs/yarg/restore_desktop_entry.sh" &' >> "$CUSTOM_SH"
fi
chmod +x "$CUSTOM_SH"

# Step 5: Create Ports script pointing directly to the game
echo "Creating YARG Ports script..."
mkdir -p "$PORTS_DIR"
cat > "$PORT_SCRIPT" << 'EOF'
#!/bin/bash
export DISPLAY=:0.0
export HOME=/userdata/system/add-ons/yarg

INSTALL_DIR="/userdata/system/add-ons/yarg"
LOG_FILE="/userdata/system/logs/yarg.log"
mkdir -p /userdata/system/logs

exec &> >(tee -a "$LOG_FILE")
echo "$(date): Launching YARG"

# Find the game binary installed by YARC Launcher
GAME=$(find "${INSTALL_DIR}/.local/share/YARC/YARG Installs" -maxdepth 4 -name 'YARG' -type f 2>/dev/null | head -1)

if [ -x "$GAME" ]; then
    echo "Found game at: $GAME"
    cd "$(dirname "$GAME")"
    ./YARG "$@"
else
    echo "YARG game not found. Launching YARC Launcher to install..."
    cd "$INSTALL_DIR"
    ./yarg-launcher.AppImage
fi
EOF
chmod +x "$PORT_SCRIPT"

# Step 6: Add to gamelist.xml
echo "Downloading YARG logo..."
curl -L -o "$LOGO_PATH" "https://yarg.in/twitter-image.png"

echo "Adding YARG to gamelist.xml..."
xmlstarlet ed -s "/gameList" -t elem -n "game" -v "" \
  -s "/gameList/game[last()]" -t elem -n "path" -v "./${APP_NAME}.sh" \
  -s "/gameList/game[last()]" -t elem -n "name" -v "$APP_NAME" \
  -s "/gameList/game[last()]" -t elem -n "image" -v "./images/yarg-logo.png" \
  "$GAME_LIST" > "$GAME_LIST.tmp" && mv "$GAME_LIST.tmp" "$GAME_LIST"

curl http://127.0.0.1:1234/reloadgames

echo
echo "Installation complete!"
echo "  - YARC Launcher available in F1 > Applications"
echo "  - Use the launcher to install YARG, then launch from Ports"


# ===== BUA post-install registration =====
if declare -F bua_register >/dev/null 2>&1; then
    bua_github_release_register || true
fi
# ===== end BUA post-install registration =====

