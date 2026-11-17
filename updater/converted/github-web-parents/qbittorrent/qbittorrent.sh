#!/usr/bin/env bash

# ===== BUA GitHub web registration adapter =====
bua_github_web_register() {
    local bua_owner='c0re100'
    local bua_repo='qBittorrent-Enhanced-Edition'

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
    bua_github_web_register || true
fi
# ===== end BUA post-install registration =====

