#!/usr/bin/env bash

# ===== BUA integration registration adapter =====

bua_integration_identity() {
    python3 - <<'PYBUA7ZIP'
import hashlib
import re
import urllib.parse
import urllib.request

page_url = "https://www.7-zip.org/download.html"

req = urllib.request.Request(
    page_url,
    headers={
        "User-Agent": "BUA-Updater",
        "Cache-Control": "no-cache",
    },
)

with urllib.request.urlopen(
    req,
    timeout=25,
) as response:
    html = response.read().decode(
        "utf-8",
        "replace",
    )

version_match = re.search(
    r"Download\s+7-Zip\s+([0-9]+\.[0-9]+)",
    html,
    re.I,
)

if not version_match:
    raise SystemExit(
        "Unable to determine latest 7-Zip version"
    )

version = version_match.group(1)

digits = version.replace(".", "")

asset_match = re.search(
    r'href=["\']([^"\']*7z'
    + re.escape(digits)
    + r'-x64\.exe)["\']',
    html,
    re.I,
)

if not asset_match:
    raise SystemExit(
        "Unable to determine latest 7-Zip x64 installer"
    )

url = urllib.parse.urljoin(
    page_url,
    asset_match.group(1),
)

identity = (
    "7zip:"
    + version
    + ":"
    + hashlib.sha256(
        url.encode("utf-8")
    ).hexdigest()
)

print(version)
print(identity)
print(url)
PYBUA7ZIP
}

if [[ "${BUA_REGISTRATION_ONLY:-0}" == "1" ]]; then
    if ! declare -F bua_register >/dev/null 2>&1; then
        echo "BUA registration helper unavailable." >&2
        exit 1
    fi

    values="$(
        bua_integration_identity
    )" || exit 1

    version="$(
        printf '%s\n' "$values" |
            sed -n '1p'
    )"

    identity="$(
        printf '%s\n' "$values" |
            sed -n '2p'
    )"

    url="$(
        printf '%s\n' "$values" |
            sed -n '3p'
    )"

    bua_register \
        "$version" \
        "vendor_web" \
        "7-zip.org" \
        "7-Zip" \
        "custom" \
        "" \
        "" \
        "" \
        "$identity" \
        "" \
        "" \
        "" \
        "" \
        "" \
        "" \
        "" \
        "" \
        "$url"

    exit $?
fi

# ===== end BUA integration registration adapter =====


# 7zip Installer for Batocera

# App Info
APPNAME="7zip"
APPLINK="https://raw.githubusercontent.com/batocera-unofficial-addons/batocera-unofficial-addons/refs/heads/main/7zip/extra/7zip.zip"
APPHOME="7-zip.org v22.01"
ICON="https://raw.githubusercontent.com/batocera-unofficial-addons/batocera-unofficial-addons/refs/heads/main/7zip/extra/7zip-icon.png"
COMMAND='batocera-wine lutris play /userdata/system/add-ons/7zip/7zip/7zFM.exe 2>/dev/null'

# Define paths
add_ons="/userdata/system/add-ons"
appdir="$add_ons/7zip"
extradir="$appdir/extra"

# Prepare directories
mkdir -p "$extradir"

# Download and install the app
cd "$extradir"
echo "Downloading $APPNAME..."
curl --progress-bar -O "$APPLINK"
unzip -oq 7zip.zip -d "$appdir"
curl --progress-bar -L -o "icon.png" "$ICON"

# Create Desktop Shortcut
shortcut="$extradir/7zip.desktop"
echo "[Desktop Entry]" > "$shortcut"
echo "Version=1.0" >> "$shortcut"
echo "Icon=$extradir/icon.png" >> "$shortcut"
echo "Exec=$COMMAND" >> "$shortcut"
echo "Terminal=false" >> "$shortcut"
echo "Type=Application" >> "$shortcut"
echo "Categories=Game;batocera.linux;" >> "$shortcut"
echo "Name=7zip" >> "$shortcut"
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
