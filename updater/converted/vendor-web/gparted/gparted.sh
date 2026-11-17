#!/bin/bash

# ===== BUA GParted upstream registration adapter =====
bua_gparted_register() {
    local bua_values

    bua_values=$(
        python3 <<'PYBUAGPARTED'
import hashlib
import re
import urllib.request

url = "https://gparted.org/"

req = urllib.request.Request(
    url,
    headers={
        "User-Agent": "Mozilla/5.0 BUA-Updater",
        "Cache-Control": "no-cache",
    },
)

with urllib.request.urlopen(
    req,
    timeout=25,
) as response:
    text = response.read().decode(
        "utf-8",
        errors="replace",
    )

match = re.search(
    r'Stable\s+release:\s*'
    r'(?:<[^>]+>\s*)*'
    r'GParted\s+'
    r'([0-9]+\.[0-9]+\.[0-9]+)',
    text,
    re.I | re.S,
)

if not match:
    match = re.search(
        r'GParted\s+'
        r'([0-9]+\.[0-9]+\.[0-9]+)',
        text,
        re.I,
    )

if not match:
    raise SystemExit(
        "Unable to determine GParted stable version"
    )

version = match.group(1)

relevant = sorted(
    line.strip()
    for line in text.splitlines()
    if (
        "Stable release" in line
        or f"GParted {version}" in line
    )
)

digest = hashlib.sha256(
    "\n".join(relevant).encode("utf-8")
).hexdigest()

print(version)
print(
    f"gparted-web:{version}:{digest}"
)
PYBUAGPARTED
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
        echo "Unable to determine GParted upstream identity." >&2
        return 1
    fi

    bua_register \
        "$bua_version" \
        "vendor_web" \
        "GParted" \
        "GParted" \
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

    bua_gparted_register
    exit $?
fi
# ===== end BUA GParted upstream registration adapter =====


# Define variables
APPNAME="GParted"
REPO_BASE_URL="https://github.com/batocera-unofficial-addons/batocera-unofficial-addons/releases/download/AppImages/"
AMD_SUFFIX="gparted.AppImage"
ARM_SUFFIX=""
ICON_URL="https://github.com/batocera-unofficial-addons/batocera-unofficial-addons/raw/main/gparted/extra/icon.png"

# Directories
ADDONS_DIR="/userdata/system/add-ons"
CONFIGS_DIR="/userdata/system/configs"
DESKTOP_DIR="/usr/share/applications"
CUSTOM_SCRIPT="/userdata/system/custom.sh"
APP_CONFIG_DIR="${CONFIGS_DIR}/${APPNAME,,}"
PERSISTENT_DESKTOP="${APP_CONFIG_DIR}/${APPNAME,,}.desktop"
DESKTOP_FILE="${DESKTOP_DIR}/${APPNAME,,}.desktop"

# Ensure directories exist
mkdir -p "$APP_CONFIG_DIR" "$ADDONS_DIR/${APPNAME,,}/extra"

# Detect system architecture
arch=$(uname -m)
case "$arch" in
    x86_64)
        appimage_url="${REPO_BASE_URL}${AMD_SUFFIX}"
        ;;
    aarch64)
        if [ -n "$ARM_SUFFIX" ]; then
            appimage_url="${REPO_BASE_URL}${ARM_SUFFIX}"
        else
            echo "No ARM64 AppImage available. Exiting."
            exit 1
        fi
        ;;
    *)
        echo "Unsupported architecture: $arch. Exiting."
        exit 1
        ;;
esac

# Download the AppImage
if ! wget -q --show-progress -O "$ADDONS_DIR/${APPNAME,,}/${APPNAME,,}.AppImage" "$appimage_url"; then
    echo "Failed to download $APPNAME AppImage. Exiting."
    exit 1
fi
chmod a+x "$ADDONS_DIR/${APPNAME,,}/${APPNAME,,}.AppImage"

# Download the application icon
if ! wget -q --show-progress -O "$ADDONS_DIR/${APPNAME,,}/extra/${APPNAME,,}-icon.png" "$ICON_URL"; then
    echo "Failed to download $APPNAME icon. Exiting."
    exit 1
fi

# Create persistent desktop entry
cat <<EOF > "$PERSISTENT_DESKTOP"
[Desktop Entry]
Version=1.0
Type=Application
Name=$APPNAME
Exec=$ADDONS_DIR/${APPNAME,,}/${APPNAME,,}.AppImage
Icon=$ADDONS_DIR/${APPNAME,,}/extra/${APPNAME,,}-icon.png
Terminal=false
Categories=Utility;batocera.linux;
EOF
chmod +x "$PERSISTENT_DESKTOP"
cp "$PERSISTENT_DESKTOP" "$DESKTOP_FILE"
chmod +x "$DESKTOP_FILE"

# Create restore script
cat <<EOF > "${APP_CONFIG_DIR}/restore_desktop_entry.sh"
#!/bin/bash
if [ ! -f "$DESKTOP_FILE" ]; then
    cp "$PERSISTENT_DESKTOP" "$DESKTOP_FILE"
    chmod +x "$DESKTOP_FILE"
fi
EOF
chmod +x "${APP_CONFIG_DIR}/restore_desktop_entry.sh"

# Add restore script to startup
if ! grep -q "${APP_CONFIG_DIR}/restore_desktop_entry.sh" "$CUSTOM_SCRIPT"; then
    echo "\"${APP_CONFIG_DIR}/restore_desktop_entry.sh\" &" >> "$CUSTOM_SCRIPT"
fi

echo "$APPNAME setup complete."


# ===== BUA post-install registration =====
if declare -F bua_register >/dev/null 2>&1; then
    bua_gparted_register || true
fi
# ===== end BUA post-install registration =====

