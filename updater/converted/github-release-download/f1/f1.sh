#!/bin/bash

# ===== BUA updater registration adapter =====
bua_github_release_register() {
    local bua_owner='DRLEdition19'
    local bua_repo='DRLEdition_Interface'

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


# Set variables
APP_NAME="F1"
LOGO_URL="https://github.com/batocera-unofficial-addons/batocera-unofficial-addons/blob/main/f1/extra/f1key.jpg?raw=true"   # Replace with actual logo URL
LOGO_PATH="/userdata/roms/ports/images/${APP_NAME}-logo.jpg"
GAME_LIST="/userdata/roms/ports/gamelist.xml"

# Temporary directory for download
TEMP_DIR="/userdata/tmp/Antimicrox"
DRL_FILE="$TEMP_DIR/Antimicrox.DRL"
EXTRACT_DIR="$TEMP_DIR/extracted"
PORTS_DIR="/userdata/roms/ports"
ADDON_BIN="/userdata/system/add-ons/f1/bin"

# Create the temporary directories
echo "Creating temporary directories..."
mkdir -p $TEMP_DIR
mkdir -p $EXTRACT_DIR
mkdir -p $PORTS_DIR
clear

# Download the DRL file
echo "Downloading the DRL file..."
curl -L -o $DRL_FILE "https://github.com/DRLEdition19/DRLEdition_Interface/releases/download/files/Antimicrox.DRL"

# Check if download was successful
if [ ! -f "$DRL_FILE" ]; then
    echo "Error: Failed to download DRL file"
    exit 1
fi

# Extract the squashfs file
echo "Extracting the DRL file..."
unsquashfs -f -d "$EXTRACT_DIR" "$DRL_FILE"

# Check if extraction was successful
if [ $? -ne 0 ]; then
    echo "Error: Failed to extract the DRL file"
    rm -rf $TEMP_DIR
    exit 1
fi

# Copy persistent userdata contents (antimicrox binary, joystick profile, etc.)
echo "Installing addon files..."
cp -r "$EXTRACT_DIR/userdata/." /userdata/

# Place binary in add-ons bin dir for symlinks.sh to pick up
mkdir -p "$ADDON_BIN"
ln -sf /userdata/system/configs/bat-drl/AntiMicroX/antimicrox "$ADDON_BIN/antimicrox"
chmod +x /userdata/system/configs/bat-drl/AntiMicroX/antimicrox

# Limpeza
echo "Cleaning up..."
rm -rf "$TEMP_DIR"

# Step 1: Create the launcher script
echo "Creating ${APP_NAME}.sh..."
cat << 'EOF' > "/userdata/roms/ports/${APP_NAME}.sh"
#!/bin/bash
# Script adapted to work with the antimicrox implemented in "Desktop for Batocera 8.0 by DRL Edition"
export XDG_MENU_PREFIX=batocera-
export XDG_CONFIG_DIRS=/etc/xdg
ANTIMICROX_PROFILE="/userdata/system/configs/bat-drl/Nav_Redist2.joystick.amgp"

# fix for exfat on HOME + pcmanfm
export XDG_CACHE_HOME=/tmp/xdg_cache
ANTIMICROX_PROFILE="/userdata/system/configs/bat-drl/Nav_Redist2.joystick.amgp"

### Inicia o AntiMicroX ###
    if [ -e '/dev/input/js0' ]; then
        antimicrox --hidden --profile "$ANTIMICROX_PROFILE" &
        ANTIMICROX_PID=$!
        success "AntiMicroX iniciado (PID: $ANTIMICROX_PID)"
    else
        warning "Nenhum joystick detectado"
    fi

### Inicia o desktop e o pcmanfm ###
batocera-mouse show
DISPLAY=${DISPLAY:-:0.0} pcmanfm /userdata
batocera-mouse hide

### Encerra o AntiMicroX, o desktop e o pcmanfm ###
    if [ -n "${ANTIMICROX_PID}" ]; then
        kill -9 "${ANTIMICROX_PID}" 2>/dev/null
        pkill -9 "${ANTIMICROX_PID}" 2>/dev/null
    fi
    
exit 0
EOF

chmod +x "/userdata/roms/ports/${APP_NAME}.sh"

clear

# Step 2: Refresh the Ports menu
echo "Refreshing Ports menu..."
curl -s http://127.0.0.1:1234/reloadgames

# Step 3: Download the logo
echo "Downloading logo..."
curl -s -L -o "$LOGO_PATH" "$LOGO_URL"

# Step 4: Add entry to gamelist.xml
echo "Adding $APP_NAME to gamelist.xml..."
xmlstarlet ed -s "/gameList" -t elem -n "game" -v "" \
  -s "/gameList/game[last()]" -t elem -n "path" -v "./${APP_NAME}.sh" \
  -s "/gameList/game[last()]" -t elem -n "name" -v "$APP_NAME" \
  -s "/gameList/game[last()]" -t elem -n "image" -v "./images/${APP_NAME}-logo.jpg" \
  "$GAME_LIST" > "$GAME_LIST.tmp" && mv "$GAME_LIST.tmp" "$GAME_LIST"

# Step 5: Final refresh
curl -s http://127.0.0.1:1234/reloadgames

echo "Done! ${APP_NAME} has been added."


# ===== BUA post-install registration =====
if declare -F bua_register >/dev/null 2>&1; then
    bua_github_release_register || true
fi
# ===== end BUA post-install registration =====

