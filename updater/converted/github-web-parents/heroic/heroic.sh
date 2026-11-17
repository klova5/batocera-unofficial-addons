#!/bin/bash

# ===== BUA GitHub web registration adapter =====
bua_github_web_register() {
    local bua_owner='Heroic-Games-Launcher'
    local bua_repo='HeroicGamesLauncher'

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


# Set variables
INSTALL_DIR="/userdata/system/add-ons/heroic"
DESKTOP_FILE="/usr/share/applications/heroic.desktop"
PERSISTENT_DESKTOP="/userdata/system/configs/heroic/heroic.desktop"
SYSTEMS_CFG="/userdata/system/configs/emulationstation/es_systems_heroic.cfg"
LAUNCHERS_SCRIPT_URL="https://github.com/batocera-unofficial-addons/batocera-unofficial-addons/raw/refs/heads/main/heroic/create_game_launchers.sh"
MONITOR_SCRIPT_URL="https://github.com/batocera-unofficial-addons/batocera-unofficial-addons/raw/refs/heads/main/heroic/monitor_heroic.sh"
WRAPPER_SCRIPT="${INSTALL_DIR}/launch_heroic.sh"
ROM_DIR="/userdata/roms/heroic"
ICON_URL="https://github.com/batocera-unofficial-addons/batocera-unofficial-addons/raw/main/heroic/extra/icon.png"
UMU_TAR_URL="https://github.com/batocera-unofficial-addons/batocera-unofficial-addons/raw/main/heroic/extra/umu.tar.gz"

[ -d "/userdata/system/add-ons/heroic" ] && rm -rf "/userdata/system/add-ons/heroic"

mkdir -p "$ROM_DIR"
mkdir -p "/userdata/system/configs/heroic"
mkdir -p "/userdata/system/add-ons/heroic/extra"

# Fetch the latest version of Heroic from GitHub API
echo "Fetching the latest version of Heroic Games Launcher..."

# First attempt: Try GitHub API
API_RESPONSE=$(wget -qO- https://api.github.com/repos/Heroic-Games-Launcher/HeroicGamesLauncher/releases/latest 2>&1)

# Check if we hit rate limit or other error
if echo "$API_RESPONSE" | grep -q "rate limit"; then
    echo "GitHub API rate limit reached. Fetching from releases page directly..."
    # Fallback: Scrape the releases page HTML
    HEROIC_URL=$(wget -qO- https://github.com/Heroic-Games-Launcher/HeroicGamesLauncher/releases/latest 2>&1 | grep -o 'https://github.com/Heroic-Games-Launcher/HeroicGamesLauncher/releases/download/v[0-9.]*/Heroic-[0-9.]*-linux-x86_64\.AppImage' | head -n 1)
else
    # Parse API response normally
    HEROIC_URL=$(echo "$API_RESPONSE" | grep "browser_download_url" | grep "linux-x86_64\.AppImage\"" | grep -v ".AppImage.zsync" | head -n 1 | cut -d '"' -f 4)
fi

HEROIC_VERSION=$(basename "$HEROIC_URL" | sed -E 's/Heroic-([^-]+).*/\1/')

if [ -z "$HEROIC_URL" ]; then
    echo "Failed to fetch the latest Heroic version. Please check your internet connection or the GitHub API."
    echo "You may have hit GitHub's rate limit. Please try again later."
    exit 1
fi

echo "Found Heroic version: $HEROIC_VERSION"
echo "Download URL: $HEROIC_URL"

# Download Heroic
echo "Downloading Heroic Games Launcher version $HEROIC_VERSION..."
mkdir -p "$INSTALL_DIR"
wget --show-progress -O "${INSTALL_DIR}/heroic.AppImage" "$HEROIC_URL"

if [ $? -ne 0 ] || [ ! -f "${INSTALL_DIR}/heroic.AppImage" ]; then
    echo "Failed to download Heroic AppImage from $HEROIC_URL"
    exit 1
fi

# Download supporting scripts
echo "Downloading create_game_launchers.sh..."
wget --show-progress -qO "${INSTALL_DIR}/create_game_launchers.sh" "$LAUNCHERS_SCRIPT_URL"

echo "Downloading monitor_heroic.sh..."
wget --show-progress -qO "${INSTALL_DIR}/monitor_heroic.sh" "$MONITOR_SCRIPT_URL"

echo "Downloading icon..."
wget --show-progress -qO "${INSTALL_DIR}/extra/icon.png" "$ICON_URL"

# Download umu runtime
echo "Downloading umu runtime..."
wget --show-progress -O "${INSTALL_DIR}/extra/umu.tar.gz" "$UMU_TAR_URL"

# Extract umu runtime
echo "Extracting umu runtime..."
tar -xzf "${INSTALL_DIR}/extra/umu.tar.gz" -C "${INSTALL_DIR}/extra"

# Make scripts executable
chmod +x "${INSTALL_DIR}/heroic.AppImage"
chmod +x "${INSTALL_DIR}/create_game_launchers.sh"
chmod +x "${INSTALL_DIR}/monitor_heroic.sh"

# Create umu symlink setup script
SETUP_UMU_SCRIPT="${INSTALL_DIR}/setup_umu_symlink.sh"
cat <<'EOL' > "$SETUP_UMU_SCRIPT"
#!/bin/bash

# Handle umu symlink
umu_target="/userdata/system/.config/heroic/tools/runtimes/umu"
umu_source="/userdata/system/add-ons/heroic/extra/umu"

# Create tools/runtimes directory if needed
mkdir -p "/userdata/system/.config/heroic/tools/runtimes" 2>/dev/null

# Wait until umu_target exists and is fully installed by checking for current_version file
while [[ ! -f "$umu_target/current_version" ]]; do
  sleep 1
done

# Check if umu was already replaced with our copy
if [[ -f "$umu_target/.replaced_by_heroic_installer" ]]; then
  # Already replaced, delete this script and exit
  rm -f "$0"
  exit 0
fi

# Replace Heroic's umu with our pre-downloaded version
rm -rf "$umu_target"
cp -r "$umu_source" "$umu_target"

# Mark that we've replaced it
touch "$umu_target/.replaced_by_heroic_installer"

# Delete this script when done
rm -f "$0"
EOL
chmod +x "$SETUP_UMU_SCRIPT"

LAUNCHER="/userdata/system/add-ons/heroic/Launcher"
cat <<'EOL' > "$LAUNCHER"
#!/bin/bash

# Run umu symlink setup script if it exists
SETUP_SCRIPT="/userdata/system/add-ons/heroic/setup_umu_symlink.sh"
if [[ -f "$SETUP_SCRIPT" ]]; then
  "$SETUP_SCRIPT" &
fi

/userdata/system/add-ons/heroic/monitor_heroic.sh &
unclutter-remote -s
DISPLAY=:0.0 /userdata/system/add-ons/heroic/heroic.AppImage --no-sandbox "$@"
EOL
chmod a+x "$LAUNCHER"

# Create launch script
echo "Creating launching script for Heroic..."
SYSTEM_LAUNCHER="/userdata/system/add-ons/heroic/SystemLauncher"
cat <<'EOL' > "$SYSTEM_LAUNCHER"
#!/bin/bash

# Run umu symlink setup script if it exists
SETUP_SCRIPT="/userdata/system/add-ons/heroic/setup_umu_symlink.sh"
if [[ -f "$SETUP_SCRIPT" ]]; then
  "$SETUP_SCRIPT" &
fi

# Process input file
ID=$(cat "$1" | head -n 1)
# Execute application
unclutter-remote -s
DISPLAY=:0.0 /userdata/system/add-ons/heroic/heroic.AppImage --no-sandbox --no-gui "heroic://launch/$ID"
EOL
chmod a+x "$SYSTEM_LAUNCHER"

# Create persistent desktop entry
echo "Creating persistent desktop entry for Heroic..."
cat <<EOF > "$PERSISTENT_DESKTOP"
[Desktop Entry]
Version=1.0
Type=Application
Name=Heroic Games Launcher
Exec=$LAUNCHER
Icon=/userdata/system/add-ons/heroic/extra/icon.png
Terminal=false
Categories=Game;batocera.linux;
EOF

chmod +x "$PERSISTENT_DESKTOP"

cp "$PERSISTENT_DESKTOP" "$DESKTOP_FILE"
chmod +x "$DESKTOP_FILE"

# Ensure the desktop entry is always restored to /usr/share/applications
echo "Ensuring Heroic desktop entry is restored at startup..."
cat <<EOF > "/userdata/system/configs/heroic/restore_desktop_entry.sh"
#!/bin/bash
# Restore Heroic desktop entry
if [ ! -f "$DESKTOP_FILE" ]; then
    echo "Restoring Heroic desktop entry..."
    cp "$PERSISTENT_DESKTOP" "$DESKTOP_FILE"
    chmod +x "$DESKTOP_FILE"
    echo "Heroic desktop entry restored."
else
    echo "Heroic desktop entry already exists."
fi
EOF
chmod +x "/userdata/system/configs/heroic/restore_desktop_entry.sh"

# Add to startup script
custom_startup="/userdata/system/custom.sh"
if ! grep -q "/userdata/system/configs/heroic/restore_desktop_entry.sh" "$custom_startup"; then
    echo "Adding Heroic restore script to startup..."
    echo "bash "/userdata/system/configs/heroic/restore_desktop_entry.sh" &" >> "$custom_startup"
fi
chmod +x "$custom_startup"

# Create es_systems_heroic.cfg
echo "Creating Heroic Category for EmulationStation..."
cat <<EOF > "$SYSTEMS_CFG"
<?xml version="1.0"?>
<systemList>
  <system>
        <fullname>heroic</fullname>
        <name>heroic</name>
        <manufacturer>Linux</manufacturer>
        <release>2017</release>
        <hardware>console</hardware>
        <path>/userdata/roms/heroic</path>
        <extension>.TXT</extension>
        <command>/userdata/system/add-ons/heroic/SystemLauncher %ROM%</command>
        <platform>pc</platform>
        <theme>heroic</theme>
        <emulators>
            <emulator name="heroic">
                <cores>
                    <core default="true">heroic</core>
                </cores>
            </emulator>
        </emulators>
  </system>

</systemList>
EOF

# Final message
echo "Heroic Games Launcher setup complete! Installed version $HEROIC_VERSION."
echo "A desktop entry has been created and will persist across reboots."
echo "Please note: not all themes support Heroic, only confirmed themes so far are ES themes."
echo "If you don't see the Heroic option after installing games,"
echo "it's likely it's instead showing up as Commodore 64. Switch to an ES theme to see Heroic properly!"
echo ""
sleep 5

killall -9 emulationstation


# ===== BUA post-install registration =====
if declare -F bua_register >/dev/null 2>&1; then
    bua_github_web_register || true
fi
# ===== end BUA post-install registration =====

