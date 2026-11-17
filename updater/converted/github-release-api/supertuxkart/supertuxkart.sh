#!/bin/bash

# ===== BUA updater registration adapter =====
bua_github_release_register() {
    local bua_owner='supertuxkart'
    local bua_repo='stk-code'

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


# Variables for SuperTuxKart
APP_NAME="SuperTuxKart"

# URLs for different architectures
LATEST=$(curl -s https://api.github.com/repos/supertuxkart/stk-code/releases/latest | grep '"tag_name"' | cut -d'"' -f4)
ARCH_X86_64="https://github.com/supertuxkart/stk-code/releases/download/${LATEST}/SuperTuxKart-${LATEST}-linux-x86_64.tar.gz"
ARCH_ARM64="https://github.com/supertuxkart/stk-code/releases/download/${LATEST}/SuperTuxKart-${LATEST}-linux-arm64.tar.gz"

LOGO_URL="https://github.com/batocera-unofficial-addons/batocera-unofficial-addons/raw/main/supertuxkart/extra/supertuxkart-logo.png"

# Determine system architecture
ARCH=$(uname -m)
if [[ "$ARCH" == "x86_64" ]]; then
    ARCHIVE_URL="$ARCH_X86_64"
elif [[ "$ARCH" == "aarch64" || "$ARCH" == "arm64" ]]; then
    ARCHIVE_URL="$ARCH_ARM64"
else
    echo "Unsupported architecture: $ARCH"
    exit 1
fi

# Directories
ADDONS_DIR="/userdata/system/add-ons"
TUX_DIR="${ADDONS_DIR}/supertuxkart"
PORTS_DIR="/userdata/roms/ports"
LOGS_DIR="/userdata/system/logs"
GAME_LIST="/userdata/roms/ports/gamelist.xml"
PORT_SCRIPT="${PORTS_DIR}/${APP_NAME}.sh"
LOGO_PATH="${PORTS_DIR}/images/${APP_NAME,,}-logo.png"

# Step 1: Ensure the target directories exist
echo "Creating required directories..."
mkdir -p "$TUX_DIR"
mkdir -p "$PORTS_DIR/images"
mkdir -p "$LOGS_DIR"

# Step 2: Download and extract SuperTuxKart
echo "Downloading $APP_NAME for architecture $ARCH..."
wget -q --show-progress -O "${TUX_DIR}/SuperTuxKart.tar.gz" "$ARCHIVE_URL"
if [ $? -ne 0 ]; then
    echo "Failed to download $APP_NAME. Exiting."
    exit 1
fi

echo "Extracting $APP_NAME..."
tar --strip-components=1 -xf "${TUX_DIR}/SuperTuxKart.tar.gz" -C "$TUX_DIR"
rm "${TUX_DIR}/SuperTuxKart.tar.gz"
chmod -R a+x "$TUX_DIR"
echo "$APP_NAME extracted to $TUX_DIR."

# Step 3: Create the app launch script
echo "Creating $APP_NAME script in Ports..."
cat << EOF > "$PORT_SCRIPT"
#!/bin/bash

# Environment setup
export \$(cat /proc/1/environ | tr '\0' '\n')
export DISPLAY=:0.0

# Directories and file paths
app_dir="$TUX_DIR"
log_dir="$LOGS_DIR"
log_file="\${log_dir}/${APP_NAME,,}.log"

# Ensure log directory exists
mkdir -p "\${log_dir}"

# Append all output to the log file
exec &> >(tee -a "\$log_file")
echo "\$(date): Launching $APP_NAME"

# Launch SuperTuxKart
if [ -d "\${app_dir}" ]; then
    cd "\${app_dir}"
    ./run_game.sh "\$@" > "\${log_file}" 2>&1
    echo "$APP_NAME exited."
else
    echo "$APP_NAME directory not found."
    exit 1
fi
EOF

chmod +x "$PORT_SCRIPT"

# Step 4: Refresh the Ports menu
echo "Refreshing Ports menu..."
curl http://127.0.0.1:1234/reloadgames

# Step 5: Download the logo
echo "Downloading $APP_NAME logo..."
wget -q -O "$LOGO_PATH" "$LOGO_URL"
if [ $? -ne 0 ]; then
    echo "Failed to download logo. Continuing without logo."
fi

# Step 6: Add to gamelist.xml
echo "Adding $APP_NAME to Ports menu..."
xmlstarlet ed -s "/gameList" -t elem -n "game" -v "" \
  -s "/gameList/game[last()]" -t elem -n "path" -v "./${APP_NAME}.sh" \
  -s "/gameList/game[last()]" -t elem -n "name" -v "$APP_NAME" \
  -s "/gameList/game[last()]" -t elem -n "image" -v "./images/${APP_NAME,,}-logo.png" \
  "$GAME_LIST" > "$GAME_LIST.tmp" && mv "$GAME_LIST.tmp" "$GAME_LIST"

curl http://127.0.0.1:1234/reloadgames

echo
echo "Installation complete! You can now launch $APP_NAME from the Ports menu."


# ===== BUA post-install registration =====
if declare -F bua_register >/dev/null 2>&1; then
    bua_github_release_register || true
fi
# ===== end BUA post-install registration =====

