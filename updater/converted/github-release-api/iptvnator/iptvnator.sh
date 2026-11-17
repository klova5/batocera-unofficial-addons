#!/bin/bash

# ===== BUA updater registration adapter =====
bua_github_release_register() {
    local bua_owner='4gray'
    local bua_repo='iptvnator'

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
    appimage_url=$(curl -s https://api.github.com/repos/4gray/iptvnator/releases/latest \
    | jq -r ".assets[] | select(.name | endswith(\".AppImage\")) | select(.name | contains(\"arm\") | not) | .browser_download_url")
elif [ "$arch" == "aarch64" ] || [ "$arch" == "arm64" ]; then
    echo "Architecture: arm64 detected."
    appimage_url=$(curl -s https://api.github.com/repos/4gray/iptvnator/releases/latest \
    | jq -r ".assets[] | select(.name | endswith(\".AppImage\")) | select(.name | contains(\"arm64\")) | .browser_download_url")
else
    echo "Unsupported architecture: $arch. Exiting."
    exit 1
fi

# Step 2: Download the AppImage
echo "Downloading IPTVNator AppImage from $appimage_url..."
mkdir -p /userdata/system/add-ons/iptvnator
wget -q --show-progress -O /userdata/system/add-ons/iptvnator/IPTVNator.AppImage "$appimage_url"

if [ $? -ne 0 ]; then
    echo "Failed to download IPTVNator AppImage."
    exit 1
fi

chmod a+x /userdata/system/add-ons/iptvnator/IPTVNator.AppImage
echo "IPTVNator AppImage downloaded and marked as executable."

# Step 3: Create persistent log directory
mkdir -p /userdata/system/logs

# Step 4: Create the IPTVNator Script
echo "Creating IPTVNator script in Ports..."
mkdir -p /userdata/roms/ports
cat << 'EOF' > /userdata/roms/ports/IPTVNator.sh
#!/bin/bash

# Environment setup
export $(cat /proc/1/environ | tr '\0' '\n')
export DISPLAY=:0.0
export HOME="/userdata/system/add-ons/iptvnator"

# Directories and file paths
app_dir="/userdata/system/add-ons/iptvnator"
app_image="${app_dir}/IPTVNator.AppImage"
log_dir="/userdata/system/logs"
log_file="${log_dir}/iptvnator.log"

# Ensure log directory exists
mkdir -p "${log_dir}"

# Append all output to the log file
exec &> >(tee -a "$log_file")
echo "$(date): Launching IPTVNator"

# Launch IPTVNator AppImage
if [ -x "${app_image}" ]; then
    cd "${app_dir}"
    ./IPTVNator.AppImage --no-sandbox > "${log_file}" 2>&1
    echo "IPTVNator exited."
else
    echo "IPTVNator.AppImage not found or not executable."
    exit 1
fi
EOF

chmod +x /userdata/roms/ports/IPTVNator.sh
KEYS_URL="https://raw.githubusercontent.com/batocera-unofficial-addons/batocera-unofficial-addons/refs/heads/main/netflix/extra/Netflix.sh.keys"
# Step 5: Download the key mapping file
echo "Downloading key mapping file..."
curl -L -o "/userdata/roms/ports/IPTVNator.sh.keys" "$KEYS_URL"

# Step 5: Refresh the Ports menu
echo "Refreshing Ports menu..."
curl http://127.0.0.1:1234/reloadgames

# Step 6: Download the image
echo "Downloading IPTVNator logo..."
curl -L -o /userdata/roms/ports/images/iptvnator-logo.png https://github.com/batocera-unofficial-addons/batocera-unofficial-addons/raw/main/iptvnator/extra/iptvnator-logo.png

echo "Adding logo to IPTVNator entry in gamelist.xml..."
xmlstarlet ed \
  -s "/gameList" -t elem -n "game" -v "" \
  -s "/gameList/game[last()]" -t elem -n "path" -v "./IPTVNator.sh" \
  -s "/gameList/game[last()]" -t elem -n "name" -v "IPTVNator" \
  -s "/gameList/game[last()]" -t elem -n "image" -v "./images/iptvnator-logo.png" \
  /userdata/roms/ports/gamelist.xml > /userdata/roms/ports/gamelist.xml.tmp \
  && mv /userdata/roms/ports/gamelist.xml.tmp /userdata/roms/ports/gamelist.xml

curl http://127.0.0.1:1234/reloadgames

echo
echo "Installation complete! You can now launch IPTVNator from the Ports menu."


# ===== BUA post-install registration =====
if declare -F bua_register >/dev/null 2>&1; then
    bua_github_release_register || true
fi
# ===== end BUA post-install registration =====

