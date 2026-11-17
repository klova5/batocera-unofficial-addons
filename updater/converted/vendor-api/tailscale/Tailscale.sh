#!/bin/bash

# ===== BUA Tailscale vendor API registration adapter =====

bua_tailscale_identity() {
    python3 <<'PYBUATS'
import json
import platform
import urllib.request

arch_map = {
    "x86_64": "amd64",
    "amd64": "amd64",
    "aarch64": "arm64",
    "arm64": "arm64",
    "armv7l": "arm",
    "armv6l": "arm",
}

machine = platform.machine()

arch = arch_map.get(machine)

if not arch:
    raise SystemExit(
        "Unsupported Tailscale architecture: "
        + machine
    )

url = (
    "https://pkgs.tailscale.com/"
    "stable/?mode=json"
)

req = urllib.request.Request(
    url,
    headers={
        "User-Agent": "BUA-Updater",
        "Cache-Control": "no-cache",
    },
)

with urllib.request.urlopen(
    req,
    timeout=20,
) as response:
    data = json.load(response)

version = str(
    data.get("TarballsVersion")
    or data.get("Version")
    or ""
).strip()

tarballs = data.get(
    "Tarballs",
    {},
)

filename = str(
    tarballs.get(arch)
    or ""
).strip()

if not version:
    raise SystemExit(
        "Tailscale version unavailable"
    )

if not filename:
    raise SystemExit(
        "Tailscale tarball unavailable for "
        + arch
    )

identity = (
    "tailscale:"
    + arch
    + ":"
    + version
    + ":"
    + filename
)

download_url = (
    "https://pkgs.tailscale.com/stable/"
    + filename
)

print(version)
print(identity)
print(download_url)
PYBUATS
}


if [[ "${BUA_REGISTRATION_ONLY:-0}" == "1" ]]; then
    if ! declare -F bua_register >/dev/null 2>&1; then
        echo "BUA registration helper unavailable." >&2
        exit 1
    fi

    values="$(
        bua_tailscale_identity
    )" || exit 1

    version="$(
        printf '%s\n' "$values" |
            sed -n '1p'
    )"

    identity="$(
        printf '%s\n' "$values" |
            sed -n '2p'
    )"

    payload_url="$(
        printf '%s\n' "$values" |
            sed -n '3p'
    )"

    bua_register \
        "$version" \
        "vendor_api" \
        "Tailscale" \
        "pkgs.tailscale.com" \
        "custom" \
        "" \
        "" \
        "" \
        "$identity" \
        "" \
        "" \
        "" \
        "" \
        "" \
        "" \
        "" \
        "" \
        "$payload_url"

    exit $?
fi

# ===== end BUA Tailscale vendor API registration adapter =====

export $(cat /proc/1/environ | tr '\0' '\n')

echo "Installing Tailscale..."
mkdir -p /userdata/temp
cd /userdata/temp || exit 1

ARCH=$(uname -m)

# Map uname -m → JSON arch key
case "$ARCH" in
  x86_64)
    TS_ARCH_KEY="amd64"
    ;;
  armv7l|armv6l)
    TS_ARCH_KEY="arm"
    ;;
  aarch64)
    TS_ARCH_KEY="arm64"
    ;;
  *)
    echo "Unsupported architecture: $ARCH"
    exit 1
    ;;
esac

echo "Detected architecture: $ARCH ($TS_ARCH_KEY)"

META_URL="https://pkgs.tailscale.com/stable/?mode=json"
echo "Fetching metadata from $META_URL ..."

JSON=$(wget -qO- "$META_URL") || {
  echo "Failed to download version metadata."
  exit 1
}

# Extract the tarball filename
FILE=$(printf '%s\n' "$JSON" \
  | grep -o "\"$TS_ARCH_KEY\" *: *\"tailscale_[^\"]*\.tgz\"" \
  | sed 's/.*": "\(.*\)".*/\1/')

if [ -z "$FILE" ]; then
  echo "Could not parse Tailscale tarball for arch '$TS_ARCH_KEY'"
  exit 1
fi

echo "Latest version tarball: $FILE"
echo "Downloading..."
wget -q "https://pkgs.tailscale.com/stable/${FILE}" || {
  echo "Failed to download Tailscale tarball."
  exit 1
}

echo "Extracting..."
tar -xf "$FILE"
DIR="${FILE%.tgz}"
cd "$DIR" || exit 1

mkdir -p /userdata/system/add-ons/tailscale

mv systemd /userdata/system/add-ons/tailscale/systemd
mv tailscale /userdata/system/add-ons/tailscale/tailscale
mv tailscaled /userdata/system/add-ons/tailscale/tailscaled

# Cleanup temporary files
cd /userdata || exit 1
rm -rf /userdata/temp

# Configure Tailscale as a service
echo "Configuring Tailscale service..."
mkdir -p /userdata/system/services
cat << 'EOF' > /userdata/system/services/tailscale
#!/bin/bash

if [[ "$1" != "start" ]]; then
  exit 0
fi

# Ensure /dev/net/tun exists
if [ ! -d /dev/net ]; then
  mkdir -p /dev/net
  mknod /dev/net/tun c 10 200
  chmod 600 /dev/net/tun
fi

# Configure IP forwarding
sysctl_config="/etc/sysctl.conf"
temp_sysctl_config="/tmp/sysctl.conf"

# Backup existing sysctl.conf (if needed)
if [ -f "$sysctl_config" ]; then
  cp "$sysctl_config" "${sysctl_config}.bak"
fi

# Apply new configurations
cat <<EOL > "$temp_sysctl_config"
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOL

mv "$temp_sysctl_config" "$sysctl_config"
sysctl -p "$sysctl_config"

# Start Tailscale daemon
/userdata/system/add-ons/tailscale/tailscaled -state /userdata/system/add-ons/tailscale/state > /userdata/system/add-ons/tailscale/tailscaled.log 2>&1 &

# Bring up Tailscale with specific options
/userdata/system/add-ons/tailscale/tailscale up --advertise-routes=192.168.1.0/24 --snat-subnet-routes=false --accept-routes
EOF

chmod +x /userdata/system/services/tailscale

# Enable and start the Tailscale service
batocera-services enable tailscale
batocera-services start tailscale
