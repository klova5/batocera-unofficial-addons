#!/bin/bash

# ===== BUA GitHub web registration adapter =====
bua_github_web_register() {
    local bua_owner='clonehero-game'
    local bua_repo='releases'

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

# BATOCERA ADD-ONS INSTALLER

# Define app information
APPNAME="CloneHero"
APPDIR="/userdata/system/add-ons/${APPNAME,,}"

# Find whichever asset name exists in this release
ASSETS=$(curl -s "https://api.github.com/repos/clonehero-game/releases/releases/latest" | grep '"browser_download_url"' | cut -d'"' -f4)

if echo "$ASSETS" | grep -q "clonehero-linux.tar.xz"; then
    APPLINK=$(echo "$ASSETS" | grep "clonehero-linux.tar.xz")
    TARFLAGS="-xJf"
elif echo "$ASSETS" | grep -q "Linux.x86_64-Standalone.tar"; then
    APPLINK=$(echo "$ASSETS" | grep "Linux.x86_64-Standalone.tar")
    TARFLAGS="-xf"
else
    echo "No recognised CloneHero Linux release asset found." >&2
    exit 1
fi

# Prepare installation directories
mkdir -p "$APPDIR/extra"
rm -rf "$APPDIR/*"

# Download and extract
TEMP_DIR="/tmp/${APPNAME,,}_download"
mkdir -p "$TEMP_DIR"
cd "$TEMP_DIR"
wget -q --show-progress -O "clonehero.tar" "$APPLINK"
tar $TARFLAGS "clonehero.tar" -C "$APPDIR" --strip-components=1
chmod +x "$APPDIR/${APPNAME,,}" 2>/dev/null || chmod +x "$APPDIR/CloneHero" 2>/dev/null
rm -rf "$TEMP_DIR"

# Detect correct binary name
if [[ -f "$APPDIR/CloneHero" ]]; then
    BINARY="$APPDIR/CloneHero"
else
    BINARY="$APPDIR/${APPNAME,,}"
fi

# Define launcher command
COMMAND='sysctl -w vm.max_map_count=2097152; ulimit -H -n 819200; ulimit -S -n 819200; ulimit -H -l 61634; ulimit -S -l 61634; ulimit -H -s 61634; ulimit -S -s 61634; mkdir '$APPDIR'/home 2>/dev/null; mkdir '$APPDIR'/config 2>/dev/null; mkdir '$APPDIR'/roms 2>/dev/null; HOME='$APPDIR'/home XDG_CONFIG_HOME='$APPDIR'/config XDG_DATA_HOME='$APPDIR'/home XDG_CURRENT_DESKTOP=XFCE DESKTOP_SESSION=XFCE DISPLAY=:0.0 '$BINARY' ${@} &'

# Create launcher script
LAUNCHER="$APPDIR/Launcher"
cat > "$LAUNCHER" << 'LAUNCHEREOF'
#!/bin/bash
~/add-ons/.dep/mousemove.sh 2>/dev/null
LAUNCHEREOF
echo "$COMMAND" >> "$LAUNCHER"
cat >> "$LAUNCHER" << 'LAUNCHEREOF'
CLONE_PID=$!

# Wait for Clone Hero window to appear (up to 60s)
for i in $(seq 1 120); do
    xdotool search --name "Clone Hero" >/dev/null 2>&1 && break
    sleep 0.5
done

# Block until window is gone
while xdotool search --name "Clone Hero" >/dev/null 2>&1; do
    sleep 1
done

wait $CLONE_PID 2>/dev/null
LAUNCHEREOF
chmod +x "$LAUNCHER"

# Create application shortcut
SHORTCUT="$APPDIR/extra/${APPNAME,,}.desktop"
echo "[Desktop Entry]" > "$SHORTCUT"
echo "Version=1.0" >> "$SHORTCUT"
echo "Icon=$APPDIR/extra/icon.png" >> "$SHORTCUT"
echo "Exec=$LAUNCHER" >> "$SHORTCUT"
echo "Terminal=false" >> "$SHORTCUT"
echo "Type=Application" >> "$SHORTCUT"
echo "Categories=Game;batocera.linux;" >> "$SHORTCUT"
echo "Name=$APPNAME" >> "$SHORTCUT"
cp "$SHORTCUT" "/usr/share/applications/${APPNAME,,}.desktop"

# Create Ports script
PORT_SCRIPT="/userdata/roms/ports/${APPNAME}.sh"
echo "#!/bin/bash" > "$PORT_SCRIPT"
echo "killall -9 ${APPNAME,,}" >> "$PORT_SCRIPT"
echo "$LAUNCHER" >> "$PORT_SCRIPT"
chmod +x "$PORT_SCRIPT"

# Add startup script
STARTUP_SCRIPT="$APPDIR/extra/startup"
echo "#!/usr/bin/env bash" > "$STARTUP_SCRIPT"
echo "cp $SHORTCUT /usr/share/applications/ 2>/dev/null" >> "$STARTUP_SCRIPT"
chmod +x "$STARTUP_SCRIPT"

# Ensure startup script runs at boot
CUSTOM_SH="/userdata/system/custom.sh"
if ! grep -Fxq "$STARTUP_SCRIPT" "$CUSTOM_SH"; then
    echo "$STARTUP_SCRIPT" >> "$CUSTOM_SH"
fi
chmod +x "$CUSTOM_SH"

# Refresh Ports menu
curl http://127.0.0.1:1234/reloadgames

# Download Clone Hero logo
LOGO_PATH="/userdata/roms/ports/images/CloneHero_Logo.png"
ICON_PATH="$APPDIR/extra/icon.png"
curl -Ls -o "$ICON_PATH" "https://github.com/batocera-unofficial-addons/batocera-unofficial-addons/raw/main/clonehero/extra/icon.png"
curl -Ls -o "$LOGO_PATH" "https://github.com/batocera-unofficial-addons/batocera-unofficial-addons/raw/main/clonehero/extra/cloneherologo.png"

# Add logo to gamelist.xml
xmlstarlet ed -s "/gameList" -t elem -n "game" -v "" \
    -s "/gameList/game[last()]" -t elem -n "path" -v "./CloneHero.sh" \
    -s "/gameList/game[last()]" -t elem -n "name" -v "Clone Hero" \
    -s "/gameList/game[last()]" -t elem -n "image" -v "./images/CloneHero_Logo.png" \
    /userdata/roms/ports/gamelist.xml > /userdata/roms/ports/gamelist.xml.tmp && mv /userdata/roms/ports/gamelist.xml.tmp /userdata/roms/ports/gamelist.xml

curl http://127.0.0.1:1234/reloadgames

exit 0


# ===== BUA post-install registration =====
if declare -F bua_register >/dev/null 2>&1; then
    bua_github_web_register || true
fi
# ===== end BUA post-install registration =====

