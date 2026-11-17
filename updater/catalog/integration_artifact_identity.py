#!/usr/bin/env python3

import hashlib
import json
import subprocess
import sys
import urllib.request


def head_metadata(url):
    """
    Prefer curl because GitHub release assets often redirect.
    Return stable remote metadata without downloading the artifact.
    """
    result = subprocess.run(
        [
            "curl",
            "-fsSIL",
            "-o",
            "/dev/null",
            "-w",
            "%{url_effective}\n"
            "%{http_code}\n"
            "%{size_download}\n",
            url,
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=30,
    )

    if result.returncode != 0:
        raise RuntimeError(
            f"HEAD failed for {url}: "
            f"{result.stderr.strip()}"
        )

    headers = subprocess.run(
        [
            "curl",
            "-fsSIL",
            url,
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=30,
    )

    if headers.returncode != 0:
        raise RuntimeError(
            f"headers failed for {url}: "
            f"{headers.stderr.strip()}"
        )

    etag = ""
    last_modified = ""
    content_length = ""

    for line in headers.stdout.splitlines():
        lower = line.lower()

        if lower.startswith("etag:"):
            etag = line.split(
                ":",
                1,
            )[1].strip()

        elif lower.startswith(
            "last-modified:"
        ):
            last_modified = line.split(
                ":",
                1,
            )[1].strip()

        elif lower.startswith(
            "content-length:"
        ):
            content_length = line.split(
                ":",
                1,
            )[1].strip()

    return {
        "url": url,
        "etag": etag,
        "last_modified": last_modified,
        "content_length": content_length,
    }


def small_content_hash(url):
    """
    Use for small scripts/configuration files where HEAD metadata
    alone may be weak or unavailable.
    """
    request = urllib.request.Request(
        url,
        headers={
            "User-Agent": "Mozilla/5.0 BUA-Updater",
            "Cache-Control": "no-cache",
        },
    )

    with urllib.request.urlopen(
        request,
        timeout=25,
    ) as response:
        data = response.read()

    return hashlib.sha256(
        data
    ).hexdigest()


def main():
    if len(sys.argv) != 2:
        raise SystemExit(
            "usage: integration_artifact_identity.py "
            "CONFIG.json"
        )

    with open(sys.argv[1]) as f:
        config = json.load(f)

    package_id = config["package_id"]

    display_version = str(
        config.get("display_version")
        or "rolling"
    )

    artifacts = []

    for item in config["artifacts"]:
        kind = item.get(
            "kind",
            "large",
        )

        url = item["url"]

        if kind == "small":
            artifacts.append({
                "url": url,
                "sha256": small_content_hash(
                    url
                ),
            })

        else:
            artifacts.append(
                head_metadata(
                    url
                )
            )

    payload = {
        "package_id": package_id,
        "display_version": display_version,
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

    print(display_version)

    print(
        f"integration:{package_id}:{digest}"
    )

    print(
        json.dumps(
            artifacts,
            indent=2,
            sort_keys=True,
        )
    )


if __name__ == "__main__":
    main()
