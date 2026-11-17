#!/bin/bash

# ===== BUA updater registration adapter =====
bua_github_release_register() {
    local bua_owner='moonlight-stream'
    local bua_repo='moonlight-qt'

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

# Step 1: Fetch the latest release of Moonlight AppImage
echo "Fetching the latest Moonlight AppImage release..."
latest_release_url=$(curl -s https://api.github.com/repos/moonlight-stream/moonlight-qt/releases/latest | grep "browser_download_url" | grep "AppImage" | cut -d '"' -f 4)

if [ -z "$latest_release_url" ]; then
    echo "Failed to retrieve the latest Moonlight release URL."
    exit 1
fi

# Step 2: Download the AppImage
echo "Downloading Moonlight AppImage from $latest_release_url..."
mkdir -p /userdata/system/add-ons/moonlight
wget -q -O /userdata/system/add-ons/moonlight/moonlight.AppImage "$latest_release_url"

if [ $? -ne 0 ]; then
    echo "Failed to download the Moonlight AppImage."
    exit 1
fi

chmod a+x /userdata/system/add-ons/moonlight/moonlight.AppImage
echo "Moonlight AppImage downloaded and marked as executable."


# Create persistent configuration and log directories
mkdir -p /userdata/system/add-ons/moonlight/moonlight-config
mkdir -p /userdata/system/logs

# Step 2: Create the Moonlight Launcher Script
echo "Creating Moonlight launcher in Ports..."
mkdir -p /userdata/roms/ports
cat << 'EOF' > /userdata/roms/ports/Moonlight.sh
#!/bin/bash

# Environment setup
export $(cat /proc/1/environ | tr '\0' '\n')
export DISPLAY=:0.0
export HOME=/userdata/system/add-ons/moonlight

# Directories and file paths
app_dir="/userdata/system/add-ons/moonlight"
config_dir="${app_dir}/moonlight-config"
config_symlink="${HOME}/.config/moonlight"
app_image="${app_dir}/moonlight.AppImage"
log_dir="/userdata/system/logs"
log_file="${log_dir}/moonlight.log"

# Ensure log directory exists
mkdir -p "${log_dir}"

# Append all output to the log file
exec &> >(tee -a "$log_file")
echo "$(date): Launching Moonlight"

# Create persistent directory for Moonlight config
mkdir -p "${config_dir}"

# Move existing config if present
if [ -d "${config_symlink}" ] && [ ! -L "${config_symlink}" ]; then
    mv "${config_symlink}" "${config_dir}"
fi

# Ensure config directory is symlinked
if [ ! -L "${config_symlink}" ]; then
    ln -sf "${config_dir}" "${config_symlink}"
fi

# Launch Moonlight AppImage
if [ -x "${app_image}" ]; then
    cd "${app_dir}"
    ./moonlight.AppImage > "${log_file}" 2>&1
    echo "Moonlight exited."
else
    echo "Moonlight.AppImage not found or not executable."
    exit 1
fi
EOF

chmod +x /userdata/roms/ports/Moonlight.sh

echo "Refreshing Ports menu..."
curl http://127.0.0.1:1234/reloadgames

# Download the image
echo "Downloading Moonlight logo..."
curl -L -o /userdata/roms/ports/images/moonlightlogo.png https://github.com/batocera-unofficial-addons/batocera-unofficial-addons/raw/main/moonlight/extra/moonlightlogo.png

echo "Adding logo to Moonlight entry in gamelist.xml..."
xmlstarlet ed -s "/gameList" -t elem -n "game" -v "" \
  -s "/gameList/game[last()]" -t elem -n "path" -v "./Moonlight.sh" \
  -s "/gameList/game[last()]" -t elem -n "name" -v "Moonlight" \
  -s "/gameList/game[last()]" -t elem -n "image" -v "./images/moonlightlogo.png" \
  /userdata/roms/ports/gamelist.xml > /userdata/roms/ports/gamelist.xml.tmp && mv /userdata/roms/ports/gamelist.xml.tmp /userdata/roms/ports/gamelist.xml


curl http://127.0.0.1:1234/reloadgames

echo
echo "Installation complete! You can now launch Moonlight from the Ports menu."


# ===== BUA post-install registration =====
if declare -F bua_register >/dev/null 2>&1; then
    bua_github_release_register || true
fi
# ===== end BUA post-install registration =====

