#!/bin/bash

# ===== BUA RGSX registration adapter =====

if [[ "${BUA_REGISTRATION_ONLY:-0}" == "1" ]]; then
    if ! declare -F bua_register >/dev/null 2>&1; then
        echo "BUA registration helper unavailable." >&2
        exit 1
    fi

    values="$(
        python3 "/userdata/system/add-ons/bua/updater/catalog/rgsx_identity.py"
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
        "github_release_asset" \
        "RetroGameSets" \
        "RGSX" \
        "custom" \
        "" \
        "" \
        "" \
        "$identity"

    exit $?
fi

# ===== end BUA RGSX registration adapter =====


'curl -L bit.ly/rgsx-install | sh'
