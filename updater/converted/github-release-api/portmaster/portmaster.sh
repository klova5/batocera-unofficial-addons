#!/bin/bash

# ===== BUA updater registration adapter =====
bua_github_release_register() {
    local bua_owner='PortsMaster'
    local bua_repo='PortMaster-GUI'

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


# Step 1: Fetch the latest PortMaster installer URL
echo "Fetching the latest PortMaster release..."
installer_url=$(curl -s https://api.github.com/repos/PortsMaster/PortMaster-GUI/releases/latest | grep "browser_download_url" | grep "Install.Full.PortMaster.sh" | cut -d '"' -f 4)

if [ -z "$installer_url" ]; then
    echo "Failed to retrieve the latest PortMaster installer URL."
    exit 1
fi

echo "Latest installer found: $installer_url"

# Step 2: Download the PortMaster installer
echo "Downloading PortMaster installer..."
mkdir -p /userdata/system/add-ons/portmaster
wget -q --show-progress -O /userdata/system/add-ons/portmaster/Install.Full.PortMaster.sh "$installer_url"

if [ $? -ne 0 ]; then
    echo "Failed to download the PortMaster installer."
    exit 1
fi

# Step 3: Make the installer executable
chmod +x /userdata/system/add-ons/portmaster/Install.Full.PortMaster.sh
echo "PortMaster installer downloaded and marked as executable."

# Step 4: Run the installer
echo "Running the PortMaster installer..."
# Disable X11/GUI mode to prevent interactive window from opening
unset DISPLAY
export TERM=linux
echo "A" | /userdata/system/add-ons/portmaster/Install.Full.PortMaster.sh

if [ $? -ne 0 ]; then
    echo "PortMaster installation failed."
    exit 1
fi

echo "Refreshing Ports menu..."
curl http://127.0.0.1:1234/reloadgames

# Download the image
echo "Downloading Port Master logo..."
curl -L -o /userdata/roms/ports/images/portmasterlogo.png https://github.com/batocera-unofficial-addons/batocera-unofficial-addons/raw/main/portmaster/extra/portmasterlogo.png

echo "Adding logo to Port Master entry in gamelist.xml..."
xmlstarlet ed -s "/gameList" -t elem -n "game" -v "" \
  -s "/gameList/game[last()]" -t elem -n "path" -v "./PortMaster.sh" \
  -s "/gameList/game[last()]" -t elem -n "name" -v "Port Master" \
  -s "/gameList/game[last()]" -t elem -n "image" -v "./images/portmasterlogo.png" \
  /userdata/roms/ports/gamelist.xml > /userdata/roms/ports/gamelist.xml.tmp && mv /userdata/roms/ports/gamelist.xml.tmp /userdata/roms/ports/gamelist.xml


curl http://127.0.0.1:1234/reloadgames

echo
echo "Installation complete! You can now launch PortMaster from the Ports menu."


# ===== BUA post-install registration =====
if declare -F bua_register >/dev/null 2>&1; then
    bua_github_release_register || true
fi
# ===== end BUA post-install registration =====

