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


# Architecture check
architecture=$(uname -m)
if [ "$architecture" != "x86_64" ]; then
    echo "This script only runs on AMD or Intel (x86_64) CPUs, not on $architecture."
    exit 1
fi

cli_apps="• Zsh (with Oh My Zsh, plugins, Powerlevel10k, .zshrc, and p10k.zsh)
• Fish (with Oh My Fish)
• Git
• Docker
• Podman
• Distrobox
• Exa
• Bat / Batcat
• Glances
• Aria2c
• Bandwhich
• Btop
• Dua
• Duf
• Fzf
• Hyperfine
• Icdiff
• Micro
• Neofetch
• Procs
• Ranger
• Rgrep
• Rip
• Scc
• Screenfetch
• Sd
• Speedtest-cli
• Strings
• Tldr
• Transfersh
• Tre
• Xmlstarlet
• Zoxide"


# Show available apps
dialog --title "Batocera-CLI Available Tools" --msgbox "The following CLI apps are included:\n$cli_apps" 30 70

# Confirm installation
dialog --stdout --title "Continue Installation?" --yesno "Would you like to proceed with installing the Batocera-CLI package?" 8 60
if [[ $? -ne 0 ]]; then
    dialog --title "Installation Canceled" --msgbox "The installation has been canceled." 8 60
    exit 1
fi

# Check for running Docker
if pgrep -x "dockerd" >/dev/null; then
    dialog --title "Error" --msgbox "Docker is currently running. Please stop or remove it first — CLI Tools includes its own Docker setup." 8 60
    exit 1
fi

# Start download
dialog --title "Downloading" --msgbox "Downloading and extracting Batocera-CLI..." 8 60

DESTINATION_DIR="/userdata/system"
FILENAME="cli.tar.xz"
DOWNLOAD_URL="https://github.com/batocera-unofficial-addons/batocera-unofficial-addons/releases/download/AppImages/cli.tar.xz"

mkdir -p "$DESTINATION_DIR"
cd "$DESTINATION_DIR"

curl -L "$DOWNLOAD_URL" -o "$FILENAME"
if [[ $? -ne 0 ]]; then
    dialog --title "Error" --msgbox "Download failed. Please check your connection and try again." 8 60
    exit 1
fi

tar -xJf "$FILENAME" -C "$DESTINATION_DIR"
rm -f "$FILENAME"
chmod +x "$DESTINATION_DIR/cli/run"

# Inform the user
dialog --title "Installation Complete" --msgbox "Batocera-CLI has been installed.\n\nYou can run it manually with:\n\n  bash /userdata/system/cli/run" 10 70

exit 0


# ===== BUA post-install registration =====
if declare -F bua_register >/dev/null 2>&1; then
    bua_github_release_register || true
fi
# ===== end BUA post-install registration =====

