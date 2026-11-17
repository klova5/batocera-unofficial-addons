#!/usr/bin/env bash

# ===== BUA integration registration adapter =====

bua_integration_identity() {
    python3 - <<'PYBUAINT'
import hashlib
import json
import subprocess
import urllib.request

config = json.loads('{"package_id":"cs-portable","display_version":"2023","artifacts":[{"kind":"large","url":"https://github.com/batocera-unofficial-addons/batocera-unofficial-addons/raw/refs/heads/main/csportable/extra/CS-Portable-2023.zip"}]}')

def large_metadata(url):
    result = subprocess.run(
        ["curl", "-fsSIL", url],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=30,
    )

    if result.returncode != 0:
        raise SystemExit(
            "Unable to inspect integration artifact: "
            + url
        )

    etag = ""
    modified = ""
    length = ""

    for line in result.stdout.splitlines():
        lower = line.lower()

        if lower.startswith("etag:"):
            etag = line.split(":", 1)[1].strip()
        elif lower.startswith("last-modified:"):
            modified = line.split(":", 1)[1].strip()
        elif lower.startswith("content-length:"):
            length = line.split(":", 1)[1].strip()

    return {
        "url": url,
        "etag": etag,
        "last_modified": modified,
        "content_length": length,
    }

def small_hash(url):
    req = urllib.request.Request(
        url,
        headers={
            "User-Agent": "BUA-Updater",
            "Cache-Control": "no-cache",
        },
    )

    with urllib.request.urlopen(
        req,
        timeout=25,
    ) as response:
        data = response.read()

    return {
        "url": url,
        "sha256": hashlib.sha256(
            data
        ).hexdigest(),
    }

artifacts = []

for item in config["artifacts"]:
    if item.get("kind") == "small":
        artifacts.append(
            small_hash(item["url"])
        )
    else:
        artifacts.append(
            large_metadata(item["url"])
        )

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
PYBUAINT
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
        "cs-portable" \
        "custom" \
        "" \
        "" \
        "" \
        "$identity"

    exit $?
fi

# ===== end BUA integration registration adapter =====


# Variables
APPNAME="CS Portable"
APPDIR="/userdata/system/add-ons/csportable"
ZIP_URL="https://github.com/batocera-unofficial-addons/batocera-unofficial-addons/raw/refs/heads/main/csportable/extra/CS-Portable-2023.zip"
ZIP_PATH="$APPDIR/CS-Portable-2023.zip"
PORT_SCRIPT="/userdata/roms/ports/CSPortable.sh"
ICON_PATH="/userdata/roms/ports/images/cs-portable-logo.jpg"
LOGO_URL="https://github.com/batocera-unofficial-addons/batocera-unofficial-addons/raw/main/csportable/extra/cs-portable-logo.jpg"
GAMELIST="/userdata/roms/ports/gamelist.xml"

# Step 2: Check if CS Portable is installed
if [[ -d $APPDIR ]]; then
  echo "$APPDIR exists. Removing it to ensure a clean setup..."
  rm -rf "$APPDIR"
fi

if [[ ! -d $APPDIR || ! -f "$APPDIR/CS Portable" ]]; then
  echo "$APPNAME is not installed. Downloading and setting up..."
  mkdir -p "$APPDIR"  # Ensure the directory exists

  # Download the ZIP file
  curl -L -o "$ZIP_PATH" "$ZIP_URL"

  # Extract the ZIP file
  unzip "$ZIP_PATH" -d "$APPDIR"

  # Remove the ZIP file after extraction
  rm "$ZIP_PATH"

  echo "$APPNAME setup completed."
fi

# Step 3: Create the ports script using EOF
mkdir -p "$(dirname "$PORT_SCRIPT")"  # Ensure the ports directory exists
mkdir -p "$(dirname "$ICON_PATH")"   # Ensure the images directory exists

cat << EOF > $PORT_SCRIPT
#!/bin/bash
DISPLAY=:0.0 "$APPDIR/CS Portable"
EOF

chmod +x $PORT_SCRIPT

# Step 4: Download the icon
echo "Downloading CS Portable logo..."
curl -L -o "$ICON_PATH" "$LOGO_URL"

# Step 6: Add CS Portable entry to gamelist.xml
echo "Updating gamelist.xml..."
xmlstarlet ed -s "/gameList" -t elem -n "game" -v "" \
  -s "/gameList/game[last()]" -t elem -n "path" -v "./CSPortable.sh" \
  -s "/gameList/game[last()]" -t elem -n "name" -v "$APPNAME" \
  -s "/gameList/game[last()]" -t elem -n "image" -v "./images/cs-portable-logo.jpg" \
  "$GAMELIST" > "${GAMELIST}.tmp" && mv "${GAMELIST}.tmp" "$GAMELIST"

# Step 7: Refresh the Ports menu
echo "Refreshing Ports menu..."
curl http://127.0.0.1:1234/reloadgames

echo "$APPNAME port setup completed. You can now access CS Portable through Ports!"
