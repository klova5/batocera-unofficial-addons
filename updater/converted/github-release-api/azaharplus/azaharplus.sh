#!/bin/bash

# ===== BUA updater registration adapter =====
bua_github_release_register() {
    local bua_owner='AzaharPlus'
    local bua_repo='AzaharPlus'

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


# Variables
install_dir="/userdata/system/add-ons/azaharplus"
es_config_dir="/userdata/system/configs/emulationstation"
user_site="/userdata/system/.local/lib/$(python3 -c 'import sys; print(f"python{sys.version_info.major}.{sys.version_info.minor}")')/site-packages"
base_url="https://github.com/batocera-unofficial-addons/batocera-unofficial-addons/raw/main/azaharplus"
bua_url="https://github.com/batocera-unofficial-addons/batocera-unofficial-addons/raw/main/app"

# Ensure BUA Python hook is present
if [ ! -f "$user_site/usercustomize.py" ]; then
    echo "Installing BUA Python hook..."
    mkdir -p "$user_site"
    wget -q --show-progress -O "$user_site/usercustomize.py" "$bua_url/usercustomize.py"
fi

# Prepare installation directory
echo "Setting up installation directory at $install_dir..."
rm -rf "$install_dir"
mkdir -p "$install_dir/generator/azaharplus"
mkdir -p "$es_config_dir"

# Get latest AzaharPlus AppImage release URL
echo "Fetching latest AzaharPlus release..."
azaharplus_url=$(curl -fsSL https://api.github.com/repos/AzaharPlus/AzaharPlus/releases/latest \
    | grep '"browser_download_url"' \
    | grep -i '\.AppImage"' \
    | head -1 \
    | cut -d '"' -f 4)

if [ -z "$azaharplus_url" ]; then
    echo "Failed to find an AzaharPlus AppImage in the latest release."
    exit 1
fi

# Download AppImage directly
echo "Downloading AzaharPlus AppImage..."
if ! wget -q --show-progress -O "$install_dir/azahar.AppImage" "$azaharplus_url"; then
    echo "Failed to download AzaharPlus."
    exit 1
fi

chmod +x "$install_dir/azahar.AppImage"

# Download generator
echo "Downloading generator..."
wget -q --show-progress -O "$install_dir/generator/azaharplus/__init__.py" "$base_url/generator/azaharplus/__init__.py"
wget -q --show-progress -O "$install_dir/generator/azaharplus/azaharplusGenerator.py" "$base_url/generator/azaharplus/azaharplusGenerator.py"

# Download and deploy ES config files
echo "Downloading ES configs..."
wget -q --show-progress -O "$es_config_dir/es_systems_3ds.cfg" "$base_url/extra/es_systems_3ds.cfg"
wget -q --show-progress -O "$es_config_dir/es_features_azaharplus.cfg" "$base_url/extra/es_features_azaharplus.cfg"

# Extract icon from AppImage
echo "Extracting icon..."
mkdir -p "$install_dir/extra"
rm -rf /tmp/azahar-icon-extract
mkdir -p /tmp/azahar-icon-extract
cd /tmp/azahar-icon-extract
"$install_dir/azahar.AppImage" --appimage-extract 'usr/share/icons/hicolor/scalable/apps/org.azahar_emu.Azahar.svg' 2>/dev/null
rsvg-convert -w 128 -h 128 \
    /tmp/azahar-icon-extract/squashfs-root/usr/share/icons/hicolor/scalable/apps/org.azahar_emu.Azahar.svg \
    -o "$install_dir/extra/icon.png"
rm -rf /tmp/azahar-icon-extract
cd /

# Create persistent desktop entry
echo "Creating desktop entry..."
desktop_file="/usr/share/applications/AzaharPlus.desktop"
persistent_desktop="/userdata/system/configs/azaharplus/AzaharPlus.desktop"
mkdir -p /userdata/system/configs/azaharplus
cat <<DESKTOP > "$persistent_desktop"
[Desktop Entry]
Version=1.0
Type=Application
Name=AzaharPlus
Exec=$install_dir/azahar.AppImage
Icon=$install_dir/extra/icon.png
Terminal=false
Categories=Game;batocera.linux;
DESKTOP
chmod +x "$persistent_desktop"
cp "$persistent_desktop" "$desktop_file"
chmod +x "$desktop_file"

# Restore desktop entry on boot
restore_script="/userdata/system/configs/azaharplus/restore_desktop_entry.sh"
cat <<RESTORE > "$restore_script"
#!/bin/bash
if [ ! -f "$desktop_file" ]; then
    cp "$persistent_desktop" "$desktop_file"
    chmod +x "$desktop_file"
fi
RESTORE
chmod +x "$restore_script"
if ! grep -q "$restore_script" /userdata/system/custom.sh; then
    echo "bash \"$restore_script\" &" >> /userdata/system/custom.sh
fi
chmod +x /userdata/system/custom.sh

# Finish
echo "AzaharPlus installation complete."
killall -9 emulationstation


# ===== BUA post-install registration =====
if declare -F bua_register >/dev/null 2>&1; then
    bua_github_release_register || true
fi
# ===== end BUA post-install registration =====

