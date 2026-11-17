#!/bin/bash

# ===== BUA updater registration adapter =====
bua_github_release_register() {
    local bua_owner='ITGmania'
    local bua_repo='ITGmania'

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
install_dir="/userdata/system/add-ons/itgmania"
ports_dir="/userdata/roms/ports"
base_url="https://github.com/batocera-unofficial-addons/batocera-unofficial-addons/raw/main/itgmania"

# Get latest ITGMania release URL
echo "Fetching latest ITGMania release..."
itgmania_url=$(curl -s https://api.github.com/repos/ITGmania/ITGmania/releases/latest \
    | grep browser_download_url \
    | grep "Linux\.tar\.gz" \
    | grep -v "no-songs" \
    | cut -d '"' -f 4)

if [ -z "$itgmania_url" ]; then
    echo "Failed to fetch ITGMania release URL. Please check your internet connection."
    exit 1
fi

# Prepare install directory
echo "Setting up installation directory at $install_dir..."
rm -rf "$install_dir"
mkdir -p "$install_dir"

# Download and extract
echo "Downloading ITGMania..."
wget -q --show-progress -O "$install_dir/itgmania.tar.gz" "$itgmania_url"

if [ $? -ne 0 ]; then
    echo "Failed to download ITGMania."
    exit 1
fi

echo "Extracting..."
tar -xzf "$install_dir/itgmania.tar.gz" -C "$install_dir" --strip-components=2
rm -f "$install_dir/itgmania.tar.gz"
chmod +x "$install_dir/itgmania"

# Create ports launcher
echo "Creating ports launcher..."
mkdir -p "$ports_dir/images"
cat << 'PORTSCRIPT' > "$ports_dir/ITGMania.sh"
#!/bin/bash
export $(cat /proc/1/environ | tr '\0' '\n')
export DISPLAY=:0.0
export HOME="/userdata/system/add-ons/itgmania"
cd /userdata/system/add-ons/itgmania
./itgmania
PORTSCRIPT
chmod +x "$ports_dir/ITGMania.sh"

# Download logo and update gamelist
echo "Downloading logo..."
curl -L -o "$ports_dir/images/itgmania-logo.png" "$base_url/extra/itgmania-logo.png"

echo "Updating gamelist..."
xmlstarlet ed -s "/gameList" -t elem -n "game" -v "" \
  -s "/gameList/game[last()]" -t elem -n "path" -v "./ITGMania.sh" \
  -s "/gameList/game[last()]" -t elem -n "name" -v "ITGMania" \
  -s "/gameList/game[last()]" -t elem -n "image" -v "./images/itgmania-logo.png" \
  "$ports_dir/gamelist.xml" > "$ports_dir/gamelist.xml.tmp" && mv "$ports_dir/gamelist.xml.tmp" "$ports_dir/gamelist.xml"
curl -s http://127.0.0.1:1234/reloadgames

echo "ITGMania installation complete."


# ===== BUA post-install registration =====
if declare -F bua_register >/dev/null 2>&1; then
    bua_github_release_register || true
fi
# ===== end BUA post-install registration =====

