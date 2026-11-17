#!/bin/bash

# ===== BUA updater registration adapter =====
bua_github_release_register() {
    local bua_owner='PrismLauncher'
    local bua_repo='PrismLauncher'

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


# Variables
INSTALL_DIR="/userdata/system/add-ons/prismlauncher"
DATA_DIR="$INSTALL_DIR/data"
DESKTOP_FILE="/usr/share/applications/prismlauncher.desktop"
PERSISTENT_DESKTOP="/userdata/system/configs/prismlauncher/prismlauncher.desktop"
RESTORE_SCRIPT="/userdata/system/configs/prismlauncher/restore_desktop_entry.sh"

# Detect architecture
arch=$(uname -m)
if [ "$arch" == "x86_64" ]; then
    APPIMAGE_PATTERN="PrismLauncher-Linux-x86_64.AppImage"
elif [ "$arch" == "aarch64" ]; then
    APPIMAGE_PATTERN="PrismLauncher-Linux-aarch64.AppImage"
else
    echo "Unsupported architecture: $arch"
    exit 1
fi

# Prepare directories
echo "Setting up Prism Launcher..."
rm -rf "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR/extra"
mkdir -p "$DATA_DIR"
mkdir -p "/userdata/system/configs/prismlauncher"
mkdir -p "/userdata/roms/ports/images"
mkdir -p "/userdata/system/logs"

# Fetch latest release URL from GitHub API
echo "Fetching latest Prism Launcher release..."
APPIMAGE_URL=$(curl -s https://api.github.com/repos/PrismLauncher/PrismLauncher/releases/latest \
    | grep browser_download_url \
    | grep "$APPIMAGE_PATTERN" \
    | cut -d '"' -f 4 \
    | head -1)

if [ -z "$APPIMAGE_URL" ]; then
    echo "Failed to fetch Prism Launcher release URL. Check your internet connection."
    exit 1
fi

echo "Downloading Prism Launcher..."
wget -q --show-progress -O "$INSTALL_DIR/prismlauncher.AppImage" "$APPIMAGE_URL"
if [ $? -ne 0 ] || [ ! -s "$INSTALL_DIR/prismlauncher.AppImage" ]; then
    echo "Download failed."
    exit 1
fi
chmod +x "$INSTALL_DIR/prismlauncher.AppImage"

# Download icon and logo
echo "Downloading icons..."
wget -q -O "$INSTALL_DIR/extra/icon.png" \
    "https://www.dockhunt.com/_next/image?url=https%3A%2F%2Fdockhunt-images.nyc3.cdn.digitaloceanspaces.com%2F5442e865-9ce3-46b2-b903-903e59bceb52&w=384&q=75"
wget -q -O "/userdata/roms/ports/images/PrismLauncher-logo.png" \
    "https://cdn2.steamgriddb.com/grid/3e07c460e84a27fa5b2426b05ad4b479.png"

# Create launch wrapper
cat <<'LAUNCH' > "$INSTALL_DIR/launch.sh"
#!/bin/bash
export $(cat /proc/1/environ | tr '\0' '\n')
export DISPLAY=:0.0
export HOME=/userdata/system/add-ons/prismlauncher
exec /userdata/system/add-ons/prismlauncher/prismlauncher.AppImage \
    --dir /userdata/system/add-ons/prismlauncher/data \
    "$@" >> /userdata/system/logs/prismlauncher.log 2>&1
LAUNCH
chmod +x "$INSTALL_DIR/launch.sh"

# Create Ports ROM entry
cat <<'ROM' > "/userdata/roms/ports/PrismLauncher.sh"
#!/bin/bash
export $(cat /proc/1/environ | tr '\0' '\n')
export DISPLAY=:0.0
export HOME=/userdata/system/add-ons/prismlauncher
exec /userdata/system/add-ons/prismlauncher/prismlauncher.AppImage \
    --dir /userdata/system/add-ons/prismlauncher/data \
    >> /userdata/system/logs/prismlauncher.log 2>&1
ROM
chmod +x "/userdata/roms/ports/PrismLauncher.sh"

# Add to ports gamelist.xml
GAMELIST="/userdata/roms/ports/gamelist.xml"
if [ ! -f "$GAMELIST" ]; then
    echo '<?xml version="1.0"?><gameList></gameList>' > "$GAMELIST"
fi
if ! grep -q "PrismLauncher.sh" "$GAMELIST"; then
    xmlstarlet ed \
        -s "/gameList" -t elem -n "game" -v "" \
        -s "/gameList/game[last()]" -t elem -n "path" -v "./PrismLauncher.sh" \
        -s "/gameList/game[last()]" -t elem -n "name" -v "Prism Launcher" \
        -s "/gameList/game[last()]" -t elem -n "image" -v "./images/PrismLauncher-logo.png" \
        -s "/gameList/game[last()]" -t elem -n "desc" -v "Open source Minecraft launcher with mod management and multi-instance support." \
        "$GAMELIST" > "${GAMELIST}.tmp" && mv "${GAMELIST}.tmp" "$GAMELIST"
fi

# Create persistent desktop entry
cat <<EOF > "$PERSISTENT_DESKTOP"
[Desktop Entry]
Version=1.0
Type=Application
Name=Prism Launcher
Comment=Open source Minecraft launcher
Exec=$INSTALL_DIR/launch.sh
Icon=$INSTALL_DIR/extra/icon.png
Terminal=false
Categories=Game;batocera.linux;
EOF
chmod +x "$PERSISTENT_DESKTOP"
cp "$PERSISTENT_DESKTOP" "$DESKTOP_FILE"
chmod +x "$DESKTOP_FILE"

# Restore desktop entry on boot
cat <<EOF > "$RESTORE_SCRIPT"
#!/bin/bash
if [ ! -f "$DESKTOP_FILE" ]; then
    cp "$PERSISTENT_DESKTOP" "$DESKTOP_FILE"
    chmod +x "$DESKTOP_FILE"
fi
EOF
chmod +x "$RESTORE_SCRIPT"
if ! grep -q "$RESTORE_SCRIPT" /userdata/system/custom.sh; then
    echo "bash \"$RESTORE_SCRIPT\" &" >> /userdata/system/custom.sh
fi
chmod +x /userdata/system/custom.sh

echo ""
echo "Prism Launcher installation complete!"
echo "Launch from Ports > Prism Launcher, or from the desktop."
echo "On first launch, sign in with your Microsoft account to play Minecraft."
echo ""
curl -s http://127.0.0.1:1234/reloadgames


# ===== BUA post-install registration =====
if declare -F bua_register >/dev/null 2>&1; then
    bua_github_release_register || true
fi
# ===== end BUA post-install registration =====

