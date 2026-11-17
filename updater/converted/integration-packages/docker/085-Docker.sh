#!/bin/bash

# ===== BUA integration-package registration adapter =====

bua_integration_register() {
    python3 - <<'PYBUAINTEGRATION'
import hashlib
import json
import subprocess
import urllib.request

config = json.loads('{"package_id":"docker","display_version":"rolling","artifacts":[{"kind":"large","url":"https://github.com/batocera-unofficial-addons/batocera-unofficial-addons/releases/download/AppImages/batocera-containers"},{"kind":"small","url":"https://raw.githubusercontent.com/batocera-unofficial-addons/batocera-unofficial-addons/refs/heads/main/docker/docker"}]}')

def head_metadata(url):
    headers = subprocess.run(
        [
            "curl",
            "-fsSIL",
            url,
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=30,
    )

    if headers.returncode != 0:
        raise SystemExit(
            "Unable to inspect integration artifact: "
            + url
        )

    etag = ""
    last_modified = ""
    content_length = ""

    for line in headers.stdout.splitlines():
        lower = line.lower()

        if lower.startswith("etag:"):
            etag = line.split(":", 1)[1].strip()

        elif lower.startswith("last-modified:"):
            last_modified = line.split(
                ":",
                1,
            )[1].strip()

        elif lower.startswith("content-length:"):
            content_length = line.split(
                ":",
                1,
            )[1].strip()

    return {
        "url": url,
        "etag": etag,
        "last_modified": last_modified,
        "content_length": content_length,
    }


def small_hash(url):
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
        data = response.read()

    return hashlib.sha256(
        data
    ).hexdigest()


artifacts = []

for item in config["artifacts"]:
    url = item["url"]

    if item.get("kind") == "small":
        artifacts.append({
            "url": url,
            "sha256": small_hash(url),
        })
    else:
        artifacts.append(
            head_metadata(url)
        )

payload = {
    "package_id": config["package_id"],
    "display_version": config["display_version"],
    "artifacts": artifacts,
}

serialized = json.dumps(
    payload,
    sort_keys=True,
    separators=(",", ":"),
).encode("utf-8")

digest = hashlib.sha256(
    serialized
).hexdigest()

print(
    config["display_version"]
)

print(
    "integration:"
    + config["package_id"]
    + ":"
    + digest
)
PYBUAINTEGRATION
}


if [[ "${BUA_REGISTRATION_ONLY:-0}" == "1" ]]; then
    if ! declare -F bua_register >/dev/null 2>&1; then
        echo "BUA registration helper unavailable." >&2
        exit 1
    fi

    values="$(
        bua_integration_register
    )" || exit 1

    version="$(
        printf '%s\n' "$values" |
            sed -n '1p'
    )"

    identity="$(
        printf '%s\n' "$values" |
            sed -n '2p'
    )"

    bua_register \
        "$version" \
        "integration_asset" \
        "BUA" \
        "docker" \
        "custom" \
        "" \
        "" \
        "" \
        "$identity"

    exit $?
fi

# ===== end BUA integration-package registration adapter =====

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

