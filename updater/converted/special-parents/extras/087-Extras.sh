#!/bin/bash

# ===== BUA Extras parent registration adapter =====

if [[ "${BUA_REGISTRATION_ONLY:-0}" == "1" ]]; then
    if ! declare -F bua_register >/dev/null 2>&1; then
        echo "BUA registration helper unavailable." >&2
        exit 1
    fi

    values="$(
        python3           /userdata/system/add-ons/bua/updater/catalog/extras_identity.py
    )" || exit 1

    version="$(
        printf '%s
' "$values" |
            sed -n '1p'
    )"

    identity="$(
        printf '%s
' "$values" |
            sed -n '2p'
    )"

    bua_register         "$version"         "github_branch"         "git-developer"         "batocera-extra"         "custom"         ""         ""         ""         "$identity"

    exit $?
fi

# ===== end BUA Extras parent registration adapter =====

#!/bin/bash

# Get Batocera version
version=$(batocera-es-swissknife --version | awk '{print $1}' | sed 's/[^0-9]*//g')

# Check if version is one of the supported ones
case "$version" in
    38|39|40|41)
        echo "Detected Batocera version: $version"
        mkdir -p /userdata/extra && \
        wget -O - "https://github.com/git-developer/batocera-extra/tarball/batocera-$version" | \
        gunzip | tar x --strip-components 1 -C /userdata/extra
        ;;
    *)
        echo "Unsupported or unknown Batocera version: $version"
        exit 1
        ;;
esac

 mkdir -p /userdata/extra && wget -O - https://github.com/git-developer/batocera-extra/tarball/main | gunzip | tar x --strip-components 1 -C /userdata/extra
 /userdata/extra/bin/extra-services register
