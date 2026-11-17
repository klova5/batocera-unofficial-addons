#!/bin/bash

# ===== BUA integration registration adapter =====

bua_integration_identity() {
    python3 - <<'PYBUAINT'
import hashlib
import json
import subprocess
import urllib.request

config = json.loads('{"package_id":"qemu-ga","display_version":"rolling","artifacts":[{"kind":"large","url":"https://github.com/batocera-unofficial-addons/batocera-unofficial-addons/raw/refs/heads/main/qga/extra/qga.tar.gz"}]}')

def large_metadata(url):
    result = subprocess.run(
        ["curl", "-fsSIL", url],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=30,
    )

    if result.returncode != 0:
        raise SystemExit(
            "Unable to inspect integration artifact: "
            + url
        )

    etag = ""
    modified = ""
    length = ""

    for line in result.stdout.splitlines():
        lower = line.lower()

        if lower.startswith("etag:"):
            etag = line.split(":", 1)[1].strip()
        elif lower.startswith("last-modified:"):
            modified = line.split(":", 1)[1].strip()
        elif lower.startswith("content-length:"):
            length = line.split(":", 1)[1].strip()

    return {
        "url": url,
        "etag": etag,
        "last_modified": modified,
        "content_length": length,
    }

def small_hash(url):
    req = urllib.request.Request(
        url,
        headers={
            "User-Agent": "BUA-Updater",
            "Cache-Control": "no-cache",
        },
    )

    with urllib.request.urlopen(
        req,
        timeout=25,
    ) as response:
        data = response.read()

    return {
        "url": url,
        "sha256": hashlib.sha256(
            data
        ).hexdigest(),
    }

artifacts = []

for item in config["artifacts"]:
    if item.get("kind") == "small":
        artifacts.append(
            small_hash(item["url"])
        )
    else:
        artifacts.append(
            large_metadata(item["url"])
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

print(config["display_version"])
print(
    "integration:"
    + config["package_id"]
    + ":"
    + digest
)
PYBUAINT
}

if [[ "${BUA_REGISTRATION_ONLY:-0}" == "1" ]]; then
    if ! declare -F bua_register >/dev/null 2>&1; then
        echo "BUA registration helper unavailable." >&2
        exit 1
    fi

    values="$(
        bua_integration_identity
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
        "qemu-ga" \
        "custom" \
        "" \
        "" \
        "" \
        "$identity"

    exit $?
fi

# ===== end BUA integration registration adapter =====


# Download and extract the addon
curl -L https://github.com/batocera-unofficial-addons/batocera-unofficial-addons/raw/refs/heads/main/qga/extra/qga.tar.gz | tar -xz -C /userdata/system/add-ons

# Create the service script
cat << 'EOF' > /userdata/system/services/qemu_ga
#!/bin/bash

QGA_BIN="/usr/bin/qemu-ga"
QGA_PID="/userdata/system/add-ons/qga/qga.pid"

start() {
  # Wait silently for /usr/bin/qemu-ga to become available
  timeout=30
  elapsed=0

  while [[ ! -x "$QGA_BIN" && $elapsed -lt $timeout ]]; do
    sleep 1
    ((elapsed++))
  done

  if [[ ! -x "$QGA_BIN" ]]; then
    exit 1
  fi

  if [[ -z "$(pidof qemu-ga)" ]]; then
    echo "Starting QEMU Guest Agent..."
    nohup "$QGA_BIN" -d -v --pidfile="$QGA_PID" >/dev/null 2>&1 &
  else
    echo "QEMU Guest Agent is already running."
  fi
}

stop() {
  echo "Stopping QEMU Guest Agent..."
  if [[ -f "$QGA_PID" ]]; then
    kill "$(cat "$QGA_PID")" && rm -f "$QGA_PID"
  else
    pkill -f qemu-ga
  fi
}

restart() {
  stop
  sleep 1
  start
}

status() {
  if pidof qemu-ga >/dev/null; then
    echo "QEMU Guest Agent is running (PID: $(pidof qemu-ga))."
  else
    echo "QEMU Guest Agent is not running."
  fi
}

case "$1" in
  start)
    start &
    ;;
  stop)
    stop
    ;;
  restart)
    restart
    ;;
  status)
    status
    ;;
  *)
    echo "Usage: $0 {start|stop|restart|status}"
    exit 1
    ;;
esac
EOF

# Make the service script executable
chmod +x /userdata/system/services/qemu_ga

# Wait silently for /usr/bin/qemu-ga to become available
timeout=30
elapsed=0

while [[ ! -x /usr/bin/qemu-ga && $elapsed -lt $timeout ]]; do
    sleep 1
    ((elapsed++))
done

if [[ ! -x /usr/bin/qemu-ga ]]; then
    exit 1
fi

batocera-services enable qemu_ga
batocera-services start qemu_ga &>/dev/null &

clear_
dialog --msgbox "QEMU Guest Agent installed and service created!\n\nTo manually control it, use:\n\nbatocera-services {start|stop|restart} qemu_ga" 10 60
clear
exit 0
