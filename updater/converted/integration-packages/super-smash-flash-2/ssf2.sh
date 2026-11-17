#!/bin/bash

# ===== BUA registration-only integration adapter =====

bua_integration_identity() {
    python3 - <<'PYBUA'
import hashlib
import json
import urllib.request

config = json.loads('{"package_id":"super-smash-flash-2","display_version":"rolling","artifacts":[{"kind":"large","url":"https://github.com/batocera-unofficial-addons/batocera-unofficial-addons/releases/download/AppImages/SSF2.wsquashfs"}]}')

artifacts = []

for item in config["artifacts"]:
    url = item["url"]

    req = urllib.request.Request(
        url,
        method="HEAD",
        headers={
            "User-Agent": "BUA-Updater",
            "Cache-Control": "no-cache",
        },
    )

    with urllib.request.urlopen(
        req,
        timeout=30,
    ) as response:
        final_url = response.geturl()

        metadata = {
            "url": url,
            "final_url": final_url,
            "etag": response.headers.get("ETag") or "",
            "last_modified": (
                response.headers.get("Last-Modified") or ""
            ),
            "content_length": (
                response.headers.get("Content-Length") or ""
            ),
        }

    artifacts.append(metadata)

payload = {
    "package_id": config["package_id"],
    "display_version": config["display_version"],
    "artifacts": artifacts,
}

serialized = json.dumps(
    payload,
    sort_keys=True,
    separators=(",", ":"),
).encode("utf-8")

digest = hashlib.sha256(
    serialized
).hexdigest()

print(config["display_version"])
print(
    "integration:"
    + config["package_id"]
    + ":"
    + digest
)
PYBUA
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

    bua_register \
        "$version" \
        "integration_asset" \
        "BUA" \
        "windows/ssf2" \
        "custom" \
        "" \
        "" \
        "" \
        "$identity"

    exit $?
fi

# ===== end BUA registration-only integration adapter =====


#!/bin/bash

# Define your variables for easy customization
URL="https://github.com/batocera-unofficial-addons/batocera-unofficial-addons/releases/download/AppImages/SSF2.wsquashfs"
KEYS_URL=""  # Leave empty if no keys file is needed
DEST_DIR="/userdata/roms/windows"
MESSAGE="Keyboard & Mouse required to set up initial controller config via in game menu."  # Leave empty if no message is needed
GAME_LIST="/userdata/roms/windows/gamelist.xml"
APP_NAME="Super Smash Flash 2"
LOGO_URL="https://github.com/batocera-unofficial-addons/batocera-unofficial-addons/raw/main/windows/extra/ssf2-logo.jpg"
LOGO_PATH="/userdata/roms/windows/images/ssf2-logo.jpg"

# Ensure destination directory exists
mkdir -p "$DEST_DIR"
mkdir -p "$(dirname "$LOGO_PATH")"

# Download the main .wsquashfs file
wget -q --show-progress -O "$DEST_DIR/$(basename "$URL")" "$URL"
if [[ $? -ne 0 ]]; then
  echo "Error downloading $URL"
  exit 1
fi

# Download the keys file if KEYS_URL is provided and accessible
if [[ -n "$KEYS_URL" ]]; then
  if wget --spider "$KEYS_URL" 2>/dev/null; then
    wget -O "$DEST_DIR/$(basename "$KEYS_URL")" "$KEYS_URL"
  else
    echo "No keys file found at $KEYS_URL. Skipping download."
  fi
fi

# Show message using dialog if MESSAGE is set
if [[ -n "$MESSAGE" ]]; then
  dialog --msgbox "$MESSAGE" 6 50
fi

curl http://127.0.0.1:1234/reloadgames

# Ensure the gamelist.xml exists
if [ ! -f "/userdata/roms/windows/gamelist.xml" ]; then
    echo '<?xml version="1.0" encoding="UTF-8"?><gameList></gameList>' > "/userdata/roms/windows/gamelist.xml"
fi

# Add game entry to gamelist.xml
if [[ -f "$GAME_LIST" ]]; then
# Download the logo
echo "Downloading $APP_NAME logo..."
curl -L -o "$LOGO_PATH" "$LOGO_URL"
echo "Adding logo to $APP_NAME entry in gamelist.xml..."
xmlstarlet ed -s "/gameList" -t elem -n "game" -v "" \
  -s "/gameList/game[last()]" -t elem -n "path" -v "./SSF2.wsquashfs" \
  -s "/gameList/game[last()]" -t elem -n "name" -v "$APP_NAME" \
  -s "/gameList/game[last()]" -t elem -n "image" -v "./images/ssf2-logo.jpg" \
  "$GAME_LIST" > "$GAME_LIST.tmp" && mv "$GAME_LIST.tmp" "$GAME_LIST"
curl http://127.0.0.1:1234/reloadgames
  
  # Reload game list
  curl http://127.0.0.1:1234/reloadgames
else
  echo "Game list file not found: $GAME_LIST"
fi

# Clear dialog box after execution
clear
