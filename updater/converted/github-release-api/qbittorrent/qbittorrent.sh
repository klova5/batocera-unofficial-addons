#!/usr/bin/env bash

# ===== BUA updater registration adapter =====
bua_github_release_register() {
    local bua_owner='c0re100'
    local bua_repo='qBittorrent-Enhanced-Edition'

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


# qBittorrent Installer for Batocera

# App Info
APPNAME="qBittorrent"
LATEST=$(curl -s https://api.github.com/repos/c0re100/qBittorrent-Enhanced-Edition/releases/latest | grep '"tag_name"' | cut -d'"' -f4)
APPLINK="https://github.com/c0re100/qBittorrent-Enhanced-Edition/releases/download/${LATEST}/qBittorrent-Enhanced-Edition-x86_64.AppImage"
APPHOME="c0re100/qBittorrent-Enhanced-Edition"
APPPATH="/userdata/system/add-ons/qbittorrent/qbittorrent.AppImage"
ICON="https://e7.pngegg.com/pngimages/380/378/png-clipart-qbittorrent-comparison-of-bittorrent-clients-others-blue-trademark.png"
COMMAND="/userdata/system/add-ons/qbittorrent/qbittorrent.AppImage"

# Define paths
add_ons="/userdata/system/add-ons"
appdir="$add_ons/qbittorrent"
extradir="$appdir/extra"

# Prepare directories
mkdir -p "$extradir"

# Download and install the app
cd "$extradir"
echo "Downloading $APPNAME..."
curl --progress-bar -L -O "$APPLINK"
chmod +x qBittorrent-Enhanced-Edition-x86_64.AppImage
mv qBittorrent-Enhanced-Edition-x86_64.AppImage "$APPPATH"
curl --progress-bar -L -o "icon.png" "$ICON"

# Create Desktop Shortcut
shortcut="$extradir/qbittorrent.desktop"
echo "[Desktop Entry]" > "$shortcut"
echo "Version=1.0" >> "$shortcut"
echo "Icon=$extradir/icon.png" >> "$shortcut"
echo "Exec=$COMMAND" >> "$shortcut"
echo "Terminal=false" >> "$shortcut"
echo "Type=Application" >> "$shortcut"
echo "Categories=Network;batocera.linux;" >> "$shortcut"
echo "Name=qBittorrent" >> "$shortcut"
chmod +x "$shortcut"
cp "$shortcut" /usr/share/applications/

# Create persistent desktop script
persistent_script="$extradir/startup.sh"
echo "#!/bin/bash" > "$persistent_script"
echo "if [ ! -f /usr/share/applications/$(basename "$shortcut") ]; then" >> "$persistent_script"
echo "    cp $shortcut /usr/share/applications/" >> "$persistent_script"
echo "fi" >> "$persistent_script"
chmod +x "$persistent_script"

# Add persistent script to custom.sh
csh="/userdata/system/custom.sh"
if ! grep -q "$persistent_script" "$csh"; then
    echo "$persistent_script &" >> "$csh"
fi

# Finish
echo "$APPNAME installed successfully."


# ===== BUA post-install registration =====
if declare -F bua_register >/dev/null 2>&1; then
    bua_github_release_register || true
fi
# ===== end BUA post-install registration =====

