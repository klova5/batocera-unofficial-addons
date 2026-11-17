#!/bin/bash

# ===== BUA GitHub web registration adapter =====
bua_github_web_register() {
    local bua_owner='jellyfin'
    local bua_repo='jellyfin-media-player'

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


# Variables
APP_NAME="Jellyfin Player"
APP_DIR_NAME="jellyfin-player"
VERSION="1.0.0"
RELEASE_BASE="https://github.com/batocera-unofficial-addons/batocera-unofficial-addons/releases/download/AppImages"
KEYS_URL="https://github.com/batocera-unofficial-addons/batocera-unofficial-addons/raw/refs/heads/main/jellyfin-client/extra/JellyfinPlayer.sh.keys"
LOGO_URL="https://raw.githubusercontent.com/batocera-unofficial-addons/batocera-unofficial-addons/main/jellyfin-client/extra/jellyfin-player-logo.jpg"

ADDONS_DIR="/userdata/system/add-ons"
PORTS_DIR="/userdata/roms/ports"
LOGS_DIR="/userdata/system/logs"
APP_INSTALL_DIR="${ADDONS_DIR}/${APP_DIR_NAME}"
PORT_SCRIPT="${PORTS_DIR}/JellyfinPlayer.sh"
KEYS_PATH="${PORTS_DIR}/JellyfinPlayer.sh.keys"
LOGO_PATH="${PORTS_DIR}/images/jellyfin-player-logo.jpg"
GAME_LIST="${PORTS_DIR}/gamelist.xml"

# Detect arch
arch=$(uname -m)
case "$arch" in
    x86_64)  APPIMAGE_URL="${RELEASE_BASE}/JellyfinPlayer-x86_64.AppImage" ;;
    aarch64) APPIMAGE_URL="${RELEASE_BASE}/JellyfinPlayer-aarch64.AppImage" ;;
    *)
        echo "Unsupported architecture: $arch. Exiting."
        exit 1
        ;;
esac

# Create install directory
mkdir -p "${APP_INSTALL_DIR}"
mkdir -p "${LOGS_DIR}"

# Download AppImage
echo "Downloading ${APP_NAME} (${arch})..."
if ! wget -q --show-progress -O "${APP_INSTALL_DIR}/JellyfinPlayer.AppImage" "${APPIMAGE_URL}"; then
    echo "Failed to download ${APP_NAME}. Exiting."
    exit 1
fi
chmod +x "${APP_INSTALL_DIR}/JellyfinPlayer.AppImage"
echo "AppImage ready at ${APP_INSTALL_DIR}/JellyfinPlayer.AppImage"

# Create Launcher script
echo "Creating Launcher..."
cat << 'EOF' > "${APP_INSTALL_DIR}/Launcher"
#!/bin/bash
~/add-ons/.dep/mousemove.sh 2>/dev/null

export DISPLAY=:0.0
export XCURSOR_THEME=Adwaita
export XCURSOR_SIZE=24

APP="/userdata/system/add-ons/jellyfin-player/JellyfinPlayer.AppImage"
"$APP" --no-sandbox --enable-smooth-scrolling
EOF
chmod +x "${APP_INSTALL_DIR}/Launcher"

# Create ports launcher
echo "Creating port script..."
mkdir -p "${PORTS_DIR}"
cat << 'EOF' > "${PORT_SCRIPT}"
#!/bin/bash
killall -9 electron 2>/dev/null
/userdata/system/add-ons/jellyfin-player/Launcher
EOF
chmod +x "${PORT_SCRIPT}"
echo "Port script created at ${PORT_SCRIPT}"

# Download keys file
echo "Downloading keys file..."
if ! curl -fsSL -o "${KEYS_PATH}" "${KEYS_URL}"; then
    echo "Warning: failed to download keys file. Controller mapping may not work."
fi

# Download logo
echo "Downloading logo..."
mkdir -p "${PORTS_DIR}/images"
curl -fsSL -o "${LOGO_PATH}" "${LOGO_URL}" || echo "Warning: failed to download logo."

# Add to ports gamelist.xml
echo "Adding entry to gamelist.xml..."
if [ ! -f "${GAME_LIST}" ]; then
    echo "<gameList />" > "${GAME_LIST}"
fi

xmlstarlet ed --inplace \
    -d "/gameList/game[path='./JellyfinPlayer.sh']" \
    -s "/gameList" -t elem -n game \
    -s "/gameList/game[last()]" -t elem -n path -v "./JellyfinPlayer.sh" \
    -s "/gameList/game[last()]" -t elem -n name -v "Jellyfin Player" \
    -s "/gameList/game[last()]" -t elem -n desc -v "Jellyfin media player with controller support" \
    -s "/gameList/game[last()]" -t elem -n image -v "./images/jellyfin-player-logo.jpg" \
    -s "/gameList/game[last()]" -t elem -n rating -v "0" \
    -s "/gameList/game[last()]" -t elem -n releasedate -v "19700101T010000" \
    -s "/gameList/game[last()]" -t elem -n hidden -v "false" \
    "${GAME_LIST}"

# Reload Ports menu
curl -s http://127.0.0.1:1234/reloadgames > /dev/null

echo ""
echo "${APP_NAME} installation complete!"
echo "Launch from the Ports menu."


# ===== BUA post-install registration =====
if declare -F bua_register >/dev/null 2>&1; then
    bua_github_web_register || true
fi
# ===== end BUA post-install registration =====

