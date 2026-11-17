#!/bin/bash

# ===== BUA GitHub web registration adapter =====
bua_github_web_register() {
    local bua_owner='moonlight-stream'
    local bua_repo='moonlight-qt'

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
    bua_github_web_register || true
fi
# ===== end BUA post-install registration =====

