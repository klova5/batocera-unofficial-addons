#!/bin/bash

# ===== BUA GitHub web registration adapter =====
bua_github_web_register() {
    local bua_owner='nzp-team'
    local bua_repo='nzportable'

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

set -euo pipefail

###############################################################################
# Nazi Zombies: Portable Installer for Batocera
###############################################################################

echo "==================================================================="
echo "Nazi Zombies: Portable Installer"
echo "==================================================================="

# Detect system architecture
echo "[*] Detecting system architecture..."
arch=$(uname -m)

case "$arch" in
    x86_64)
        echo "    Architecture: x86_64 detected"
        DOWNLOAD_URL="https://github.com/nzp-team/nzportable/releases/download/nightly/nzportable-linux64.zip"
        BINARY_NAME="nzportable64-sdl"
        ;;
    aarch64|armv8*|arm64)
        echo "    Architecture: ARM64/aarch64 detected"
        DOWNLOAD_URL="https://github.com/nzp-team/nzportable/releases/download/nightly/nzportable-linuxarm64.zip"
        BINARY_NAME="nzportablearm64-sdl"
        ;;
    *)
        echo "[!] Error: Unsupported architecture: $arch"
        echo "    Supported architectures: x86_64, ARM64/aarch64"
        exit 1
        ;;
esac

# Setup directories
INSTALL_DIR="/userdata/roms/ports/nzp"
TEMP_ZIP="/tmp/nzp.zip"

echo "[*] Creating installation directory..."
mkdir -p "${INSTALL_DIR}"

# Download latest nightly build
echo "[*] Downloading Nazi Zombies: Portable..."
echo "    URL: ${DOWNLOAD_URL}"
if command -v wget >/dev/null 2>&1; then
    wget -q --show-progress -O "${TEMP_ZIP}" "${DOWNLOAD_URL}"
elif command -v curl >/dev/null 2>&1; then
    curl -L -o "${TEMP_ZIP}" "${DOWNLOAD_URL}"
else
    echo "[!] Error: Neither wget nor curl found!"
    exit 1
fi

# Extract the zip file
echo "[*] Extracting archive..."
cd "${INSTALL_DIR}"
unzip -o "${TEMP_ZIP}"

# Clean up
rm -f "${TEMP_ZIP}"

# Make binary executable
chmod +x "${INSTALL_DIR}/${BINARY_NAME}"

# Create launcher script
echo "[*] Creating launcher script..."
PORTS_DIR="/userdata/roms/ports"
LAUNCHER_SCRIPT="${PORTS_DIR}/Nazi Zombies Portable.sh"

cat > "${LAUNCHER_SCRIPT}" <<LAUNCHER_EOF
#!/bin/bash
cd /userdata/roms/ports/nzp
./${BINARY_NAME}
LAUNCHER_EOF

chmod +x "${LAUNCHER_SCRIPT}"

# Download logo
echo "[*] Downloading logo..."
mkdir -p "${PORTS_DIR}/images"
curl -L -o "${PORTS_DIR}/images/nzp-logo.png" \
  "https://media.moddb.com/images/articles/1/51/50682/nzp.png" 2>/dev/null || true

# Add entry to gamelist.xml
echo "[*] Adding entry to gamelist.xml..."
if [ -f /userdata/roms/ports/gamelist.xml ]; then
    xmlstarlet ed -s "/gameList" -t elem -n "game" -v "" \
      -s "/gameList/game[last()]" -t elem -n "path" -v "./Nazi Zombies Portable.sh" \
      -s "/gameList/game[last()]" -t elem -n "name" -v "Nazi Zombies Portable" \
      -s "/gameList/game[last()]" -t elem -n "image" -v "./images/nzp-logo.png" \
      /userdata/roms/ports/gamelist.xml > /userdata/roms/ports/gamelist.xml.tmp && \
      mv /userdata/roms/ports/gamelist.xml.tmp /userdata/roms/ports/gamelist.xml
fi

# Refresh EmulationStation game list
echo "[*] Refreshing EmulationStation..."
curl -s http://127.0.0.1:1234/reloadgames >/dev/null 2>&1 || true

echo ""
echo "==================================================================="
echo "Nazi Zombies: Portable installed successfully!"
echo "==================================================================="
echo ""
echo "Launch from: Ports > Nazi Zombies Portable"
echo ""
echo "Installation location: /userdata/roms/ports/nzp"
echo ""
echo "==================================================================="


# ===== BUA post-install registration =====
if declare -F bua_register >/dev/null 2>&1; then
    bua_github_web_register || true
fi
# ===== end BUA post-install registration =====

