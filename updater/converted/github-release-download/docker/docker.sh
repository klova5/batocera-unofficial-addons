#!/bin/bash

# ===== BUA updater registration adapter =====
bua_github_release_register() {
    local bua_owner='batocera-unofficial-addons'
    local bua_repo='batocera-unofficial-addons'

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

# UPDATED 2025-11-14

# Step 1: Detect system architecture
echo "Detecting system architecture..."
arch=$(uname -m)

if [ "$arch" == "x86_64" ]; then
    echo "Architecture: x86_64 detected."
    url="https://github.com/batocera-unofficial-addons/batocera-unofficial-addons/releases/download/AppImages/batocera-containers"
elif [ "$arch" == "aarch64" ]; then
    echo "Architecture: aarch64 detected."
    url="https://github.com/batocera-unofficial-addons/batocera-unofficial-addons/releases/download/AppImages/batocera-containers-aarch64"
else
    echo "Unsupported architecture: $arch. Exiting."
    exit 1
fi

echo "Preparing & Downloading Docker & Podman..."

# Define the directory and the URL for the file
directory="$HOME/batocera-containers"
filename="batocera-containers" # Explicitly set the filename

# Create the directory if it doesn't exist
mkdir -p "$directory"

# Change to the directory
cd "$directory"

# Download the file with the specified filename
wget -q --show-progress "$url" -O "$filename"

# Make the file executable
chmod +x "$filename"

echo "File '$filename' downloaded and made executable in '$directory/$filename'"

# Add the command to ~/custom.sh before starting Docker and Portainer
custom_startup="/userdata/system/custom.sh"
restore_script="/userdata/system/batocera-containers/batocera-containers"

if ! grep -q "$restore_script" "$custom_startup" 2>/dev/null; then
    echo "Adding batocera-containers to startup..."
    echo "bash $restore_script &" >> "$custom_startup"
fi
chmod +x "$custom_startup"

cd ~/batocera-containers

clear
echo "Starting Docker..."
echo ""
~/batocera-containers/batocera-containers

# Install Portainer
echo "Installing portainer.."
echo ""
docker volume create portainer_data
docker run --device /dev/dri:/dev/dri --privileged --net host --ipc host -d --name portainer --restart=always -v /var/run/docker.sock:/var/run/docker.sock -v /media:/media -v portainer_data:/data portainer/portainer-ce:latest

curl -Ls https://github.com/batocera-unofficial-addons/batocera-unofficial-addons/raw/refs/heads/main/docker/docker -o /userdata/system/services/docker && chmod +x /userdata/system/services/docker
batocera-services enable docker
batocera-services start docker

dialog --title "Installation Complete" --msgbox "Done!\n\nYou can now access the Portainer GUI at:\n\nhttps://<batoceraipaddress>:9443" 10 50
clear
exit


# ===== BUA post-install registration =====
if declare -F bua_register >/dev/null 2>&1; then
    bua_github_release_register || true
fi
# ===== end BUA post-install registration =====

