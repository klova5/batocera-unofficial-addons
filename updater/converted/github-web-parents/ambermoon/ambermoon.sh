#!/bin/bash

# ===== BUA GitHub web registration adapter =====
bua_github_web_register() {
    local bua_owner='Pyrdacor'
    local bua_repo='Ambermoon.net'

    local bua_values

    bua_values=$(
        python3 - "$bua_owner" "$bua_repo" <<'PYBUAGH'
import hashlib
import html
import json
import re
import sys
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

owner, repo = sys.argv[1:3]

UA = "Mozilla/5.0 BUA-Updater"


def request(url):
    req = urllib.request.Request(
        url,
        headers={
            "User-Agent": UA,
            "Cache-Control": "no-cache",
        },
    )

    with urllib.request.urlopen(
        req,
        timeout=25,
    ) as response:
        return (
            response.geturl(),
            response.read(),
        )


def latest_tag():
    latest_url = (
        f"https://github.com/{owner}/{repo}/"
        "releases/latest"
    )

    try:
        final_url, _ = request(latest_url)

        match = re.search(
            r"/releases/tag/([^/?#]+)",
            final_url,
        )

        if match:
            return urllib.parse.unquote(
                match.group(1)
            )

    except Exception:
        pass

    # Nightly/prerelease fallback.
    atom_url = (
        f"https://github.com/{owner}/{repo}/"
        "releases.atom"
    )

    _, body = request(atom_url)

    root = ET.fromstring(body)

    ns = {
        "atom": "http://www.w3.org/2005/Atom",
    }

    entries = root.findall(
        "atom:entry",
        ns,
    )

    for entry in entries:
        link = entry.find(
            "atom:link",
            ns,
        )

        if link is None:
            continue

        href = link.attrib.get(
            "href",
            "",
        )

        match = re.search(
            r"/releases/tag/([^/?#]+)",
            href,
        )

        if match:
            return urllib.parse.unquote(
                match.group(1)
            )

    raise RuntimeError(
        "Unable to determine GitHub release tag"
    )


def asset_fingerprint(tag):
    encoded_tag = urllib.parse.quote(
        tag,
        safe="",
    )

    url = (
        f"https://github.com/{owner}/{repo}/"
        f"releases/expanded_assets/{encoded_tag}"
    )

    _, body = request(url)

    text = html.unescape(
        body.decode(
            "utf-8",
            errors="replace",
        )
    )

    href_pattern = re.compile(
        rf'href="(/'
        rf'{re.escape(owner)}/'
        rf'{re.escape(repo)}/'
        r'releases/download/[^"]+)"',
        re.I,
    )

    hrefs = sorted(
        set(
            href_pattern.findall(text)
        )
    )

    datetimes = sorted(
        set(
            re.findall(
                r'datetime="([^"]+)"',
                text,
                re.I,
            )
        )
    )

    sizes = sorted(
        set(
            re.findall(
                r'([0-9]+(?:\.[0-9]+)?\s*'
                r'(?:Bytes|KB|MB|GB|KiB|MiB|GiB))',
                text,
                re.I,
            )
        )
    )

    payload = {
        "owner": owner,
        "repo": repo,
        "tag": tag,
        "assets": hrefs,
        "datetimes": datetimes,
        "sizes": sizes,
    }

    encoded = json.dumps(
        payload,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")

    return hashlib.sha256(
        encoded
    ).hexdigest()


tag = latest_tag()

digest = asset_fingerprint(
    tag
)

identity = (
    "github-web:"
    + tag
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
        echo "BUA registration helper unavailable." >&2
        exit 1
    fi

    bua_github_web_register
    exit $?
fi
# ===== end BUA GitHub web registration adapter =====


# Variables specific to Ambermoon
APP_NAME="Ambermoon"
LOGO_URL="https://github.com/batocera-unofficial-addons/batocera-unofficial-addons/raw/main/ambermoon/extra/ambermoon-logo.png"
LATEST=$(curl -s https://api.github.com/repos/Pyrdacor/Ambermoon.net/releases/latest | grep '"tag_name"' | cut -d'"' -f4)
FILE_URL="https://github.com/Pyrdacor/Ambermoon.net/releases/download/${LATEST}/Ambermoon.net-Linux.tar.gz"

ADDONS_DIR="/userdata/system/add-ons"
PORTS_DIR="/userdata/roms/ports"
LOGS_DIR="/userdata/system/logs"
GAME_LIST="/userdata/roms/ports/gamelist.xml"
PORT_SCRIPT="${PORTS_DIR}/${APP_NAME}.sh"
LOGO_PATH="${PORTS_DIR}/images/${APP_NAME,,}-logo.png"
CONFIG_FILE="${ADDONS_DIR}/${APP_NAME,,}/ambermoon.cfg"
TAR_FILE="$ADDONS_DIR/${APP_NAME,,}/Ambermoon.tar.gz"

# Step 1: Create necessary directories
echo "Setting up directories..."
mkdir -p "$ADDONS_DIR/${APP_NAME,,}" "$PORTS_DIR" "$LOGS_DIR" "$PORTS_DIR/images"

# Step 2: Download and extract Ambermoon
echo "Downloading $APP_NAME..."
wget -q --show-progress -O "$TAR_FILE" "$FILE_URL"

if [ $? -ne 0 ]; then
    echo "Failed to download $APP_NAME. Exiting."
    exit 1
fi

# Extract the downloaded file
echo "Extracting $APP_NAME..."
tar -xzvf "$TAR_FILE" -C "$ADDONS_DIR/${APP_NAME,,}"

if [ $? -ne 0 ]; then
    echo "Failed to extract $APP_NAME. Exiting."
    exit 1
fi

# Remove the .tar.gz file after extraction
echo "Cleaning up..."
rm -f "$TAR_FILE"

# Step 3: Create ambermoon.cfg if it doesn't exist
if [ ! -f "$CONFIG_FILE" ]; then
    echo "Creating default configuration file for $APP_NAME..."
    cat << EOF > "$CONFIG_FILE"
{
  "UsePatcher": true,
  "PatcherTimeout": 1250,
  "UseProxyForPatcher": false,
  "PatcherProxy": "",
  "WindowX": 0,
  "WindowY": 0,
  "MonitorIndex": 0,
  "Fullscreen": true,
  "UseDataPath": false,
  "DataPath": "/userdata/system/add-ons/ambermoon",
  "SaveOption": 0,
  "GameVersionIndex": 1,
  "LegacyMode": false,
  "Music": true,
  "Volume": 100,
  "ExternalMusic": false,
  "BattleSpeed": 0,
  "AutoDerune": true,
  "EnableCheats": false,
  "ShowButtonTooltips": true,
  "ShowFantasyIntro": true,
  "ShowIntro": false,
  "GraphicFilter": 0,
  "GraphicFilterOverlay": 0,
  "Effects": 0,
  "ShowPlayerStatsTooltips": true,
  "ShowPyrdacorLogo": true,
  "ShowFloor": true,
  "ShowCeiling": true,
  "ShowFog": true,
  "ExtendedSavegameSlots": true,
  "AdditionalSavegameSlots": [],
  "ShowSaveLoadMessage": false,
  "Movement3D": 0,
  "TurnWithArrowKeys": true,
  "Language": 0
}
EOF
else
    echo "Configuration file already exists. Skipping creation."
fi

# Step 4: Create the app launch script
echo "Creating launch script..."
cat << EOF > "$PORT_SCRIPT"
#!/bin/bash

# Environment setup
export \$(cat /proc/1/environ | tr '\0' '\n')
export DISPLAY=:0.0

# Launch Ambermoon
cd "$ADDONS_DIR/${APP_NAME,,}"
./Ambermoon.net "\$@"
EOF

chmod +x "$PORT_SCRIPT"

# Step 5: Refresh the Ports menu
echo "Refreshing Ports menu..."
curl http://127.0.0.1:1234/reloadgames

# Step 6: Download the logo
echo "Downloading logo..."
curl -L -o "$LOGO_PATH" "$LOGO_URL"

# Step 7: Add entry to gamelist.xml
echo "Adding $APP_NAME to gamelist.xml..."
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
    bua_github_web_register || true
fi
# ===== end BUA post-install registration =====

