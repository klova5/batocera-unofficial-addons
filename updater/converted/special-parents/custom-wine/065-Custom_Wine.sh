#!/bin/bash

# ===== BUA Custom Wine hub registration adapter =====

bua_custom_wine_identity() {
    python3 - <<'PYBUACW'
import hashlib
import json
import urllib.request

config = json.loads('{"package_id":"custom-wine","display_version":"rolling","artifacts":[{"kind":"small","url":"https://raw.githubusercontent.com/batocera-unofficial-addons/batocera-unofficial-addons/main/wine-custom/vanilla.sh"},{"kind":"small","url":"https://raw.githubusercontent.com/batocera-unofficial-addons/batocera-unofficial-addons/main/wine-custom/tkg.sh"},{"kind":"small","url":"https://raw.githubusercontent.com/batocera-unofficial-addons/batocera-unofficial-addons/main/wine-custom/wine-ge.sh"},{"kind":"small","url":"https://raw.githubusercontent.com/batocera-unofficial-addons/batocera-unofficial-addons/main/wine-custom/ge-proton.sh"},{"kind":"small","url":"https://raw.githubusercontent.com/batocera-unofficial-addons/batocera-unofficial-addons/main/wine-custom/steamy.sh"},{"kind":"small","url":"https://raw.githubusercontent.com/batocera-unofficial-addons/batocera-unofficial-addons/main/v40wine/v40wine.sh"}]}')

artifacts = []

for item in config["artifacts"]:
    url = item["url"]

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

    artifacts.append({
        "url": url,
        "sha256": hashlib.sha256(
            data
        ).hexdigest(),
    })

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
PYBUACW
}

if [[ "${BUA_REGISTRATION_ONLY:-0}" == "1" ]]; then
    if ! declare -F bua_register >/dev/null 2>&1; then
        echo "BUA registration helper unavailable." >&2
        exit 1
    fi

    values="$(
        bua_custom_wine_identity
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
        "integration_hub" \
        "BUA" \
        "custom-wine" \
        "custom" \
        "" \
        "" \
        "" \
        "$identity"

    exit $?
fi

# ===== end BUA Custom Wine hub registration adapter =====


# Use dialog menu to display the selection menu
CHOICE=$(dialog --stdout --title "Select Wine Version" --menu "Choose which Wine/Proton version to install:" 20 70 6 \
    "vanilla" "Wine & Proton (vanilla/regular)" \
    "tkg" "Wine-TKG-Staging" \
    "wine-ge" "Wine-GE Custom" \
    "ge-proton" "GE-Proton" \
    "steamy" "Steamy-AIO Wine Dependency Installer" \
    "v40" "V40 Stock Wine")

if [ -z "$CHOICE" ]; then
    echo "Installation cancelled."
    exit 1
fi

# Run the appropriate script based on the user's choice
case $CHOICE in
    vanilla)
        echo "You chose Wine Vanilla and Proton."
        curl -L https://github.com/batocera-unofficial-addons/batocera-unofficial-addons/raw/main/wine-custom/vanilla.sh | bash
        ;;
    tkg)
        echo "You chose Wine-tkg staging."
        curl -L https://github.com/batocera-unofficial-addons/batocera-unofficial-addons/raw/main/wine-custom/tkg.sh | bash
        ;;
    wine-ge)
        echo "You chose Wine-GE Custom."
        curl -L  https://github.com/batocera-unofficial-addons/batocera-unofficial-addons/raw/main/wine-custom/wine-ge.sh | bash
        ;;
    ge-proton)
        echo "You chose GE-Proton."
        curl -L  https://github.com/batocera-unofficial-addons/batocera-unofficial-addons/raw/main/wine-custom/ge-proton.sh | bash
        ;;
    steamy)
        echo "You chose Steamy-AIO."
        curl -L  https://github.com/batocera-unofficial-addons/batocera-unofficial-addons/raw/main/wine-custom/steamy.sh | bash
        ;;
    v40)
        echo "You chose V40 stock wine."
        curl -L https://github.com/batocera-unofficial-addons/batocera-unofficial-addons/raw/main/v40wine/v40wine.sh | bash
        ;;
    *)
        echo "Invalid choice or no choice made. Exiting."
        ;;
esac
