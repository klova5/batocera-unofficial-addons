#!/bin/bash

# ===== BUA Switch registration adapter =====

if [[ "${BUA_REGISTRATION_ONLY:-0}" == "1" ]]; then
    if ! declare -F bua_register >/dev/null 2>&1; then
        echo "BUA registration helper unavailable." >&2
        exit 1
    fi

    values="$(
        python3 "/userdata/system/add-ons/bua/updater/catalog/switch_identity.py"
    )" || exit 1

    version="$(
        printf '%s\n' "$values" |
            sed -n '1p'
    )"

    identity="$(
        printf '%s\n' "$values" |
            sed -n '2p'
    )"

    owner="$(
        printf '%s\n' "$values" |
            sed -n '3p'
    )"

    repo="$(
        printf '%s\n' "$values" |
            sed -n '4p'
    )"

    components_json="$(
        printf '%s\n' "$values" |
            sed -n '5p'
    )"

    if [[ -z "$components_json" ]]; then
        echo "Unable to resolve Switch component metadata." >&2
        exit 1
    fi

    bua_register \
        "$version" \
        "multi_parent" \
        "$owner" \
        "$repo" \
        "custom" \
        "" \
        "" \
        "" \
        "$identity" \
        "" \
        "" \
        "" \
        "multi_component" \
        "/userdata/system/switch/appimages" \
        "" \
        "" \
        "" \
        "" \
        "$components_json"

    exit $?
fi

# ===== end BUA Switch registration adapter =====


# Check if rgs.version exists
if [ -f "/userdata/system/rgs.version" ]; then
    dialog --msgbox "Team Pixel Nostalgia's build supports Switch emulation natively. No need to install it via BUA." 8 60
    clear
    exit 0
fi

curl -L bit.ly/foclabroc-switch-all | bash
