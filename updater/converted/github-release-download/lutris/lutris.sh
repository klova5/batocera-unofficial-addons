#!/bin/bash

# ===== BUA updater registration adapter =====
bua_github_release_register() {
    local bua_owner='batocera-unofficial-addons'
    local bua_repo='batocera-unofficial-addons'

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

if [ "$arch" == "x86_64" ]; then
    echo "Architecture: x86_64 detected."
    appimage_url="https://github.com/batocera-unofficial-addons/batocera-unofficial-addons/releases/download/AppImages/"
else
    echo "Unsupported architecture: $arch. Exiting."
    exit 1
fi

# Check if fusermount3 exists
if ! command -v fusermount3 &> /dev/null; then
    
    # Display a YES/NO dialog
    dialog --stdout --yesno "BUA needs to be updated to the latest version for this app to run. Do you want to continue?" 10 60
    response=$?
    if [ $response -eq 0 ]; then
    clear
        echo "Updating BUA..."
        curl -L bit.ly/BUAinstaller | bash
    else
        echo "Update declined. Exiting."
        exit 1
    fi
fi

# Step 2: Download Lutris Parts
echo "Downloading Lutris parts..."
mkdir -p /userdata/system/add-ons/lutris
wget -q --show-progress -O /userdata/system/add-ons/lutris/lutris_part_aa "$appimage_url/lutris_part_aa"
wget -q --show-progress -O /userdata/system/add-ons/lutris/lutris_part_bb "$appimage_url/lutris_part_ab"

if [ $? -ne 0 ]; then
    echo "Failed to download Lutris parts."
    exit 1
fi

# Reassemble the Lutris package
echo "Reassembling Lutris package..."
cat /userdata/system/add-ons/lutris/lutris_part_* > /userdata/system/add-ons/lutris/lutris.tar.xz

# Extract Lutris package
echo "Extracting Lutris..."
tar -xf /userdata/system/add-ons/lutris/lutris.tar.xz -C /userdata/system/add-ons/lutris/

chmod a+x /userdata/system/add-ons/lutris/lutris
echo "Lutris reassembled, extracted, and marked as executable."

# Remove the tar.xz file after extraction
rm /userdata/system/add-ons/lutris/lutris.tar.xz
rm /userdata/system/add-ons/lutris/lutris_part_*

# Create persistent configuration and log directories
mkdir -p /userdata/system/logs
mkdir -p /userdata/system/configs/lutris
mkdir -p /userdata/system/add-ons/lutris/extra
DESKTOP_FILE="/usr/share/applications/Lutris.desktop"
PERSISTENT_DESKTOP="/userdata/system/configs/lutris/Lutris.desktop"
ICON_URL="https://github.com/batocera-unofficial-addons/batocera-unofficial-addons/raw/main/lutris/extra/icon.png"
INSTALL_DIR="/userdata/system/add-ons/lutris"

# Step 3: Create the Lutris Launcher Script
echo "Creating Lutris launcher script in Ports..."
mkdir -p /userdata/roms/ports
cat << 'EOF' > /userdata/roms/ports/Lutris.sh
#!/bin/bash
export DISPLAY=:0.0

cd /userdata/system/add-ons/lutris
ulimit -H -n 819200 && ulimit -S -n 819200 && sysctl -w fs.inotify.max_user_watches=8192000 vm.max_map_count=2147483642 fs.file-max=8192000 >/dev/null 2>&1 && dbus-run-session ./lutris
EOF

cat << 'EOF' > /userdata/system/add-ons/lutris/Launcher
#!/bin/bash
export DISPLAY=:0.0

ulimit -H -n 819200 && ulimit -S -n 819200 && sysctl -w fs.inotify.max_user_watches=8192000 vm.max_map_count=2147483642 fs.file-max=8192000 >/dev/null 2>&1 && dbus-run-session /userdata/system/add-ons/lutris/lutris
EOF

chmod +x /userdata/roms/ports/Lutris.sh
chmod +x /userdata/system/add-ons/lutris/Launcher

echo "Downloading icon..."
wget --show-progress -qO "${INSTALL_DIR}/extra/icon.png" "$ICON_URL"

# Create persistent desktop entry
echo "Creating persistent desktop entry for Lutris..."
cat <<EOF > "$PERSISTENT_DESKTOP"
[Desktop Entry]
Version=1.0
Type=Application
Name=Lutris
Exec=/userdata/system/add-ons/lutris/Launcher
Icon=/userdata/system/add-ons/lutris/extra/icon.png
Terminal=false
Categories=Game;batocera.linux;
EOF

chmod +x "$PERSISTENT_DESKTOP"

cp "$PERSISTENT_DESKTOP" "$DESKTOP_FILE"
chmod +x "$DESKTOP_FILE"

# Ensure the desktop entry is always restored at startup
echo "Ensuring Lutris desktop entry is restored at startup..."
cat <<EOF > "/userdata/system/configs/lutris/restore_desktop_entry.sh"
#!/bin/bash
# Restore Lutris desktop entry
if [ ! -f "$DESKTOP_FILE" ]; then
    echo "Restoring Lutris desktop entry..."
    cp "$PERSISTENT_DESKTOP" "$DESKTOP_FILE"
    chmod +x "$DESKTOP_FILE"
    echo "Lutris desktop entry restored."
else
    echo "Lutris desktop entry already exists."
fi
EOF
chmod +x "/userdata/system/configs/lutris/restore_desktop_entry.sh"

# Add to startup script
custom_startup="/userdata/system/custom.sh"
if ! grep -q "/userdata/system/configs/lutris/restore_desktop_entry.sh" "$custom_startup"; then
    echo "Adding Lutris restore script to startup..."
    echo "bash \"/userdata/system/configs/lutris/restore_desktop_entry.sh\" &" >> "$custom_startup"
fi
chmod +x "$custom_startup"

echo "Refreshing Ports menu..."
curl http://127.0.0.1:1234/reloadgames

KEYS_URL="https://raw.githubusercontent.com/batocera-unofficial-addons/batocera-unofficial-addons/refs/heads/main/lutris/extra/Lutris.sh.keys"
# Step 5: Download the key mapping file
echo "Downloading key mapping file..."
curl -L -o "/userdata/roms/ports/Lutris.sh.keys" "$KEYS_URL"
# Download the image
echo "Downloading Lutris logo..."
curl -L -o /userdata/roms/ports/images/lutrislogo.jpg https://github.com/batocera-unofficial-addons/batocera-unofficial-addons/raw/main/lutris/extra/logo.jpg

echo "Adding logo to Lutris entry in gamelist.xml..."
xmlstarlet ed -s "/gameList" -t elem -n "game" -v "" \
  -s "/gameList/game[last()]" -t elem -n "path" -v "./Lutris.sh" \
  -s "/gameList/game[last()]" -t elem -n "name" -v "Lutris" \
  -s "/gameList/game[last()]" -t elem -n "image" -v "./images/lutrislogo.jpg" \
  /userdata/roms/ports/gamelist.xml > /userdata/roms/ports/gamelist.xml.tmp && mv /userdata/roms/ports/gamelist.xml.tmp /userdata/roms/ports/gamelist.xml

curl http://127.0.0.1:1234/reloadgames

echo
echo "Installation complete! You can now launch Lutris from the F1 Applications menu and the Ports menu."


# ===== BUA post-install registration =====
if declare -F bua_register >/dev/null 2>&1; then
    bua_github_release_register || true
fi
# ===== end BUA post-install registration =====

