#!/bin/bash

# ===== BUA updater registration adapter =====
bua_github_release_register() {
    local bua_owner='LizardByte'
    local bua_repo='Sunshine'

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


# Step 1: Install Sunshine
echo "Installing Sunshine..."

# Create target directory
mkdir -p /userdata/system/add-ons/sunshine

# Fetch latest AppImage URL and download it
APPIMAGE_URL=$(curl -s https://api.github.com/repos/LizardByte/Sunshine/releases/latest | grep browser_download_url | grep AppImage | cut -d '"' -f 4)

if [ -n "$APPIMAGE_URL" ]; then
    curl -L "$APPIMAGE_URL" -o /userdata/system/add-ons/sunshine/sunshine.AppImage
    chmod +x /userdata/system/add-ons/sunshine/sunshine.AppImage
    echo "Sunshine installed successfully."
else
    echo "Failed to fetch the latest Sunshine AppImage URL."
fi

# Create a persistent configuration directory
mkdir -p /userdata/system/logs

# Configure Sunshine as a service
echo "Configuring Sunshine service..."
mkdir -p /userdata/system/services
cat << 'EOF' > /userdata/system/services/sunshine
#!/bin/bash
#
# sunshine service script for Batocera
# Functional start/stop/restart/status (update)/uninstall

# Environment setup
export $(cat /proc/1/environ | tr '\0' '\n')
export DISPLAY=:0.0
export HOME=/userdata/system/add-ons/sunshine

# Directories and file paths
app_dir="/userdata/system/add-ons/sunshine"
app_image="${app_dir}/sunshine.AppImage"
log_dir="/userdata/system/logs"
log_file="${log_dir}/sunshine.log"

# Ensure log directory exists
mkdir -p "${log_dir}"


# Append all output to the log file
exec &> >(tee -a "$log_file")
echo "$(date): ${1} service sunshine"

case "$1" in
    start)
        echo "Starting Sunshine service..."

        # Start Sunshine AppImage
        if [ -x "${app_image}" ]; then
            cd "${app_dir}"
            ./sunshine.AppImage > "${log_file}" 2>&1 &
            echo "Sunshine started successfully."
        else
            echo "Sunshine.AppImage not found or not executable."
            exit 1
        fi
        ;;
    stop)
        echo "Stopping Sunshine service..."
        # Stop the specific processes for sunshine.AppImage
        pkill -f "./sunshine.AppImage" && echo "Sunshine stopped." || echo "Sunshine is not running."
        pkill -f "/tmp/.mount_sunshi" && echo "Sunshine child process stopped." || echo "Sunshine child process is not running."
        ;;
restart)
    "$0" stop
    "$0" start
    ;;
    status)
        if pgrep -f "sunshine.AppImage" > /dev/null; then
            echo "Sunshine is running."
            exit 0
        else
            echo "Sunshine is stopped. Going to update now"
            curl -L https://raw.githubusercontent.com/batocera-unofficial-addons/batocera-unofficial-addons/main/sunshine/sunshine.sh | bash
            exit 1
        fi
        ;;
    uninstall)
        echo "Uninstalling Sunshine service..."
        "$0" stop
        rm -f "${app_image}"
        echo "Sunshine uninstalled successfully."
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|status(update)|uninstall}"
        exit 1
        ;;
esac

exit $?

EOF

chmod +x /userdata/system/services/sunshine

echo "Applying Nvidia patches for a smoother experience..."
# Apply Nvidia patches if necessary
curl -L https://github.com/batocera-unofficial-addons/batocera-unofficial-addons/raw/main/nvidiapatch/nvidiapatch.sh | bash

# Enable and start the Sunshine service
batocera-services enable sunshine
batocera-services start sunshine


echo
dialog --msgbox "Installation complete!\n\nPlease head to https://YOUR-MACHINE-IP:47990 to pair Sunshine with Moonlight if this is your first time running Sunshine :)" 10 60


# ===== BUA post-install registration =====
if declare -F bua_register >/dev/null 2>&1; then
    bua_github_release_register || true
fi
# ===== end BUA post-install registration =====

