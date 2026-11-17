#!/usr/bin/env bash

# ===== BUA integration registration adapter =====

bua_integration_identity() {
    python3 - <<'PYBUAINT'
import hashlib
import json
import subprocess
import urllib.request

config = json.loads('{"package_id":"java-runtime","display_version":"rolling","artifacts":[{"kind":"large","url":"https://raw.githubusercontent.com/batocera-unofficial-addons/batocera-unofficial-addons/main/java/extra/java.tar.bz2.partaa"},{"kind":"large","url":"https://raw.githubusercontent.com/batocera-unofficial-addons/batocera-unofficial-addons/main/java/extra/java.tar.bz2.partab"}]}')

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
        "java-runtime" \
        "custom" \
        "" \
        "" \
        "" \
        "$identity"

    exit $?
fi

# ===== end BUA integration registration adapter =====


# Define App Info
APPNAME=java
APPHOME=azul.com/downloads
APPPATH=/userdata/system/add-ons/$APPNAME/$APPNAME.AppImage

# Define Launcher Command
COMMAND='mkdir -p /userdata/system/add-ons/'$APPNAME'/home /userdata/system/add-ons/'$APPNAME'/config /userdata/system/add-ons/'$APPNAME'/roms 2>/dev/null; \
HOME=/userdata/system/add-ons/'$APPNAME'/home XDG_CONFIG_HOME=/userdata/system/add-ons/'$APPNAME'/config QT_SCALE_FACTOR="1" GDK_SCALE="1" XDG_DATA_HOME=/userdata/system/add-ons/'$APPNAME'/home DISPLAY=:0.0 /userdata/system/add-ons/'$APPNAME'/'$APPNAME'.AppImage --no-sandbox'

# Prepare Paths and Files
mkdir -p /userdata/system/add-ons/$APPNAME/extra
echo "$COMMAND" > /userdata/system/add-ons/$APPNAME/extra/command

# Download Necessary Files
curl -s -Lo /userdata/system/add-ons/$APPNAME/extra/icon.png \
    https://github.com/batocera-unofficial-addons/batocera-unofficial-addons/raw/main/$APPNAME/extra/icon.png || { echo "Download failed! Exiting..."; exit 1; }

# Check System Compatibility
if ! uname -a | grep -q 'x86_64'; then 
    echo "ERROR: SYSTEM NOT SUPPORTED. You need Batocera x86_64."
    exit 1
fi

# Download Java Runtime
mkdir -p /userdata/system/add-ons/$APPNAME/extra/downloads
cd /userdata/system/add-ons/$APPNAME/extra/downloads

for part in java.tar.bz2.partaa java.tar.bz2.partab; do
    curl -s --progress-bar --remote-name --location \
        https://github.com/batocera-unofficial-addons/batocera-unofficial-addons/raw/main/$APPNAME/extra/$part || { echo "Download failed! Exiting..."; exit 1; }
done

# Merge and Extract Java Files
cat java.tar.bz2.parta* > java.tar.gz
mkdir -p /userdata/system/add-ons/java
tar -xjf java.tar.gz --strip-components=1 -C /userdata/system/add-ons/java

# Update Profile and Bashrc
for file in /userdata/system/.profile /userdata/system/.bashrc; do
    if [[ -f "$file" ]]; then
        grep -qxF 'export PATH=/userdata/system/add-ons/java/bin:$PATH && export JAVA_HOME=/userdata/system/add-ons/java' "$file" || \
        echo 'export PATH=/userdata/system/add-ons/java/bin:$PATH && export JAVA_HOME=/userdata/system/add-ons/java' >> "$file"
    else
        echo 'export PATH=/userdata/system/add-ons/java/bin:$PATH && export JAVA_HOME=/userdata/system/add-ons/java' >> "$file"
    fi
done

# Create Launcher Script
LAUNCHER=/userdata/system/add-ons/$APPNAME/Launcher
cat <<EOF > $LAUNCHER
#!/bin/bash
export PATH=/userdata/system/add-ons/java/bin:\$PATH
export JAVA_HOME=/userdata/system/add-ons/java

if command -v java &> /dev/null; then
    java --version
else
    echo "Java not found! Installation might have failed."
fi
EOF
chmod +x $LAUNCHER

# Create Application Shortcut
DESKTOP_ENTRY=/userdata/system/add-ons/$APPNAME/extra/$APPNAME.desktop
cat <<EOF > $DESKTOP_ENTRY
[Desktop Entry]
Version=1.0
Icon=/userdata/system/add-ons/$APPNAME/extra/icon.png
Exec=/userdata/system/add-ons/$APPNAME/Launcher
Terminal=false
Type=Application
Categories=Game;batocera.linux;
Name=$APPNAME
EOF
chmod +x $DESKTOP_ENTRY
cp $DESKTOP_ENTRY /usr/share/applications/ 2>/dev/null

# Auto-run on Boot
CUSTOM_SH=/userdata/system/custom.sh
if ! grep -q "/userdata/system/add-ons/$APPNAME/extra/startup" "$CUSTOM_SH"; then
    echo -e "\n/userdata/system/add-ons/$APPNAME/extra/startup" >> "$CUSTOM_SH"
fi
chmod +x "$CUSTOM_SH"

# Final Output
echo "$APPNAME installation complete."
