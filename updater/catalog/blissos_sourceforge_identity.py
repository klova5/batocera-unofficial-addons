#!/usr/bin/env python3

import hashlib
import html
import re
import sys
import urllib.request

VARIANTS = {
    "blissos16-generic": {
        "page": (
            "https://sourceforge.net/projects/"
            "blissos-x86/files/Official/"
            "BlissOS16/Gapps/Generic/"
        ),
        "pattern": re.compile(
            r'Bliss-v'
            r'([0-9]+\.[0-9]+\.[0-9]+)'
            r'-x86_64-OFFICIAL-gapps-'
            r'([0-9]{8})\.iso'
        ),
    },

    "blissos16-go": {
        "page": (
            "https://sourceforge.net/projects/"
            "blissos-x86/files/Official/"
            "BlissOS16/Gapps/Go/"
        ),
        "pattern": re.compile(
            r'Bliss-Go-v'
            r'([0-9]+\.[0-9]+\.[0-9]+)'
            r'-x86_64-OFFICIAL-gapps-'
            r'([0-9]{8})\.iso'
        ),
    },
}


def version_key(value):
    return tuple(
        int(part)
        for part in value.split(".")
    )


def resolve(variant):
    config = VARIANTS.get(variant)

    if not config:
        raise SystemExit(
            f"Unknown variant: {variant}"
        )

    request = urllib.request.Request(
        config["page"],
        headers={
            "User-Agent": "Mozilla/5.0 BUA-Updater",
            "Cache-Control": "no-cache",
        },
    )

    with urllib.request.urlopen(
        request,
        timeout=25,
    ) as response:
        text = response.read().decode(
            "utf-8",
            errors="replace",
        )

    text = html.unescape(text)

    found = []

    for match in config["pattern"].finditer(text):
        version = match.group(1)
        build_date = match.group(2)
        filename = match.group(0)

        found.append(
            (
                version_key(version),
                build_date,
                version,
                filename,
            )
        )

    if not found:
        raise SystemExit(
            "Unable to find BlissOS ISO "
            f"for {variant}"
        )

    # Highest semantic version first, then newest dated build
    # when several builds share the same app version.
    found.sort(
        reverse=True
    )

    _, build_date, version, filename = found[0]

    identity_payload = "\n".join(
        [
            variant,
            version,
            build_date,
            filename,
        ]
    ).encode("utf-8")

    digest = hashlib.sha256(
        identity_payload
    ).hexdigest()

    identity = (
        "sourceforge:"
        + variant
        + ":"
        + version
        + ":"
        + build_date
        + ":"
        + digest
    )

    print(version)
    print(identity)
    print(filename)


if len(sys.argv) != 2:
    raise SystemExit(
        "usage: blissos_sourceforge_identity.py "
        "VARIANT"
    )

resolve(
    sys.argv[1]
)
