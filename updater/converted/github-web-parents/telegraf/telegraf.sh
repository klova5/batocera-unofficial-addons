#!/usr/bin/env bash

# ===== BUA GitHub web registration adapter =====
bua_github_web_register() {
    local bua_owner='influxdata'
    local bua_repo='telegraf'

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


# Telegraf installer for Batocera
# Adds monitoring support using Telegraf

set -euo pipefail

export $(cat /proc/1/environ | tr '\0' '\n')

# https://github.com/influxdata/telegraf/releases
SERVICE_NAME="telegraf"
REPO="influxdata/${SERVICE_NAME}"
INSTALL_DIR="/userdata/system/add-ons/${SERVICE_NAME}"

FILEBase=${FILEBase:-"${SERVICE_NAME}-"}
FILEVersion=""  # will be set later

LOG_FILE="/userdata/system/logs/${SERVICE_NAME}-install.log"
mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1

FORCE=false
CHECK_ONLY=false
VERSION_OVERRIDE=""

print_help() {
    echo "Usage: $0 [--check-only] [--force] [--version=x.y.z]"
    echo ""
    echo "Options:"
    echo "  --check-only       Only show installed and latest version, then exit."
    echo "  --force            Force install even if latest version is already installed."
    echo "  --version=x.y.z    Install a specific version instead of the latest."
    echo "  --help, -h         Show this help message."
    exit 0
}

# Parse args
for arg in "$@"; do
    case "$arg" in
        --force)
          FORCE=true
          ;;
        --check-only)
          CHECK_ONLY=true
          ;;
        --version=*)
          VERSION_OVERRIDE="${arg#*=}"
          ;;
        --help|-h)
          print_help
          ;;
    esac
done

echo "==== $(date): Starting telegraf.sh ===="

# Dependency check
for cmd in wget awk sed grep tee; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "Missing required command: $cmd"
        exit 1
    fi
done

# Check installed version
if [ -x /userdata/system/add-ons/telegraf/telegraf ]; then
    INSTALLED_VERSION=$(/userdata/system/add-ons/telegraf/telegraf --version | awk '{print $2}')
    echo "Installed version: $INSTALLED_VERSION"
else
    INSTALLED_VERSION="none"
    echo "Telegraf not currently installed."
fi

# Determine target version
if [[ -n "$VERSION_OVERRIDE" ]]; then
    TARGET_VERSION="$VERSION_OVERRIDE"
    echo "Using override version: $TARGET_VERSION"
else
    echo "Fetching latest version from GitHub..."
    LATEST_VERSION=$(wget -qO- "https://api.github.com/repos/${REPO}/releases/latest" | grep '"tag_name":' | sed -E 's/.*"v?([^\"]+)".*/\1/')
    TARGET_VERSION="$LATEST_VERSION"
    echo "Latest available version: $TARGET_VERSION"
fi

FILEVersion="$TARGET_VERSION"

# Check-only mode
if $CHECK_ONLY; then
    echo "Installed: $INSTALLED_VERSION"
    echo "Available: $TARGET_VERSION"
    exit 0
fi

# If already installed and matches, skip unless forced
if [[ "$INSTALLED_VERSION" == "$TARGET_VERSION" ]] && ! $FORCE; then
    echo "Already running version $INSTALLED_VERSION. Use --force to reinstall."
    exit 0
fi

# Stop running service
if command -v batocera-services &>/dev/null; then
    echo "Stopping Telegraf via batocera-services..."
    batocera-services stop "$SERVICE_NAME" || echo "Warning: failed to stop $SERVICE_NAME"
else
    echo "batocera-services not found. Please stop Telegraf manually."
    exit 1
fi

ARCH=$(uname -m)

case "$ARCH" in
  x86_64)
    FILE="${FILEBase}${FILEVersion}_linux_amd64.tar.gz"
    ;;
  armv7l)
    FILE="${FILEBase}${FILEVersion}_linux_armhf.tar.gz"
    ;;
  aarch64)
    FILE="${FILEBase}${FILEVersion}_linux_arm64.tar.gz"
    ;;
  *)
    echo "Unsupported architecture: $ARCH"
    exit 1
    ;;
esac

mkdir -p /userdata/temp-${SERVICE_NAME}
cd /userdata/temp-${SERVICE_NAME} || exit 1

echo "Detected architecture: $ARCH"
echo "Downloading $FILE..."
wget -q "https://dl.influxdata.com/telegraf/releases/${FILE}"

echo "Extracting..."
tar -xf "$FILE"
DIR="${FILEBase}${FILEVersion}"
cd "$DIR" || exit 1

mkdir -p /userdata/system/add-ons/telegraf/etc/telegraf/telegraf.d
mkdir -p /userdata/system/add-ons/telegraf/log

mv -vf usr/lib/telegraf/scripts/telegraf.service /userdata/system/add-ons/telegraf
mv -vf usr/bin/telegraf /userdata/system/add-ons/telegraf/telegraf
cp -vf etc/telegraf/telegraf.conf /userdata/system/add-ons/telegraf/etc/telegraf/telegraf.conf.default
# We don't want to mess with an already setup Telegraf
if [ ! -f /userdata/system/add-ons/telegraf/telegraf.conf ]; then
  mv -v etc/telegraf/telegraf.conf /userdata/system/add-ons/telegraf/etc/telegraf
fi

# Cleanup temporary files
cd /userdata || exit 1
rm -rf /userdata/temp-${SERVICE_NAME}

# Configure Telegraf as a service
echo "Configuring Telegraf service..."
mkdir -p /userdata/system/services

cat << 'EOF' > /userdata/system/services/telegraf
#!/usr/bin/env bash
# Telegraf service for batocera

set -euo pipefail

case "$1" in
  start)
    echo "Start Telegraf daemon"
    /userdata/system/add-ons/telegraf/telegraf \
      --config /userdata/system/add-ons/telegraf/etc/telegraf/telegraf.conf \
      --config-directory /userdata/system/add-ons/telegraf/etc/telegraf/telegraf.d \
        > /userdata/system/add-ons/telegraf/log/telegraf.log 2>&1 &
    ;;
  stop)
    pkill -f "/userdata/system/add-ons/telegraf/telegraf"
    ;;
  restart)
    "$0" stop
    sleep 1
    "$0" start
    ;;
  *)  echo "Unrecognised option: $1"
    exit 0
    ;;
esac
EOF

chmod +x /userdata/system/services/telegraf

# Enable and start the Telegraf service
batocera-services enable telegraf
batocera-services start telegraf

echo "Install complete. You may now start the service:"
echo "  batocera-services start $SERVICE_NAME"


# ===== BUA post-install registration =====
if declare -F bua_register >/dev/null 2>&1; then
    bua_github_web_register || true
fi
# ===== end BUA post-install registration =====

