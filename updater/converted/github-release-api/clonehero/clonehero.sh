#!/bin/bash

# ===== BUA updater registration adapter =====
bua_github_release_register() {
    local bua_owner='clonehero-game'
    local bua_repo='releases'

    local bua_values

    bua_values=$(
        python3 - "$bua_owner" "$bua_repo" <<'PYBUAGH'
import hashlib
import json
import sys
import urllib.request

owner, repo = sys.argv[1:3]

url = (
    "https://api.github.com/repos/"
    f"{owner}/{repo}/releases/latest"
)

req = urllib.request.Request(
    url,
    headers={
        "User-Agent": "BUA-Updater",
        "Accept": "application/vnd.github+json",
        "Cache-Control": "no-cache",
    },
)

with urllib.request.urlopen(
    req,
    timeout=25,
) as response:
    release = json.loads(
        response.read().decode("utf-8")
    )

tag = str(
    release.get("tag_name") or ""
).strip()

if not tag:
    raise SystemExit(
        "GitHub release has no tag_name"
    )

assets = []

for asset in release.get("assets") or []:
    assets.append({
        "id": asset.get("id"),
        "name": asset.get("name"),
        "size": asset.get("size"),
        "updated_at": asset.get("updated_at"),
    })

identity_payload = {
    "release_id": release.get("id"),
    "release_updated_at": release.get("updated_at"),
    "assets": sorted(
        assets,
        key=lambda a: (
            str(a.get("name") or ""),
            str(a.get("id") or ""),
        ),
    ),
}

serialized = json.dumps(
    identity_payload,
    sort_keys=True,
    separators=(",", ":"),
).encode("utf-8")

digest = hashlib.sha256(
    serialized
).hexdigest()

identity = (
    "github-release:"
    + str(release.get("id") or "unknown")
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
        echo "BUA registration helper is unavailable." >&2
        exit 1
    fi

    bua_github_release_register
    exit $?
fi
# ===== end BUA updater registration adapter =====

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
    bua_github_release_register || true
fi
# ===== end BUA post-install registration =====

