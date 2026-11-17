#!/usr/bin/env python3

import hashlib
import html
import json
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET


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


def latest_tag(owner, repo):
    """
    Preferred path:
      github.com/OWNER/REPO/releases/latest
        -> redirects to /releases/tag/TAG

    Fallback:
      github.com/OWNER/REPO/releases.atom
        -> newest release entry
    """
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

    # Fallback for repositories where "latest" is unavailable,
    # such as prerelease/nightly-only projects.
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

    if not entries:
        raise RuntimeError(
            "GitHub releases feed contains no entries"
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
        "Unable to determine release tag "
        "from GitHub releases feed"
    )


def release_assets(owner, repo, tag):
    encoded_tag = urllib.parse.quote(
        tag,
        safe="",
    )

    url = (
        f"https://github.com/{owner}/{repo}/"
        f"releases/expanded_assets/{encoded_tag}"
    )

    _, body = request(url)

    text = body.decode(
        "utf-8",
        errors="replace",
    )

    text = html.unescape(text)

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

    # GitHub's expanded-assets fragment normally contains
    # timestamps. Include them so replacing an asset while
    # keeping the same filename can still alter the identity.
    datetimes = sorted(
        set(
            re.findall(
                r'datetime="([^"]+)"',
                text,
                re.I,
            )
        )
    )

    # Also include displayed byte/size text where available.
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

    if not hrefs:
        # Some valid GitHub releases contain no binary assets.
        # The tag is still an authoritative update identity.
        return {
            "hrefs": [],
            "datetimes": datetimes,
            "sizes": sizes,
        }

    return {
        "hrefs": hrefs,
        "datetimes": datetimes,
        "sizes": sizes,
    }


def build_identity(owner, repo):
    tag = latest_tag(
        owner,
        repo,
    )

    assets = release_assets(
        owner,
        repo,
        tag,
    )

    payload = {
        "owner": owner,
        "repo": repo,
        "tag": tag,
        "assets": assets,
    }

    encoded = json.dumps(
        payload,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")

    digest = hashlib.sha256(
        encoded
    ).hexdigest()

    identity = (
        "github-web:"
        + tag
        + ":"
        + digest
    )

    return tag, identity


def main():
    if len(sys.argv) != 3:
        raise SystemExit(
            "usage: "
            "github_web_release_identity.py "
            "OWNER REPO"
        )

    owner, repo = sys.argv[1:3]

    tag, identity = build_identity(
        owner,
        repo,
    )

    print(tag)
    print(identity)


if __name__ == "__main__":
    main()
