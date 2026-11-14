"""
GitHub API access for the BUA updater (BUA_GITHUB_API_CACHE_V1).

Every GitHub REST API GET made by the updater goes through here: the
frontend installs it in-process, and registration adapters get it via
sitecustomize (pyhooks/), so their embedded python3 calls are covered
too. Unauthenticated clients get 60 requests per hour, which a full scan
of every app exceeds; this module

  - caches each API response on disk (outside updater/, so reinstalls
    keep it) and reuses it for BUA_GITHUB_CACHE_TTL seconds (6 h);
  - once GitHub reports the rate limit, stops calling it until the reset
    time, answering from the cache meanwhile (even if older than the
    TTL), or failing with a clear "rate limit reached until HH:MM";
  - uses a token when one is configured (BUA_GITHUB_TOKEN / GITHUB_TOKEN,
    or /userdata/system/add-ons/bua/github-token), which raises the limit
    to 5,000 per hour and makes unchanged answers (304) free.

Only GET requests to api.github.com are affected; everything else is
passed through untouched.
"""

import base64
import email.message
import hashlib
import io
import json
import os
import threading
import time
import urllib.error
import urllib.request
import urllib.response
from urllib.parse import urlsplit

CACHE_DIR = os.environ.get(
    "BUA_GITHUB_CACHE_DIR",
    "/userdata/system/add-ons/bua/.updater-cache/github-api",
)
TOKEN_FILE = "/userdata/system/add-ons/bua/github-token"
TTL = int(os.environ.get("BUA_GITHUB_CACHE_TTL", str(6 * 3600)))
LIMIT_FILE = "rate-limit.json"
MAX_BODY = 8 * 1024 * 1024

_lock = threading.Lock()
_original_urlopen = None


def _token():
    for name in ("BUA_GITHUB_TOKEN", "GITHUB_TOKEN"):
        value = os.environ.get(name, "").strip()
        if value:
            return value
    try:
        with open(TOKEN_FILE, encoding="utf-8") as handle:
            value = handle.read().strip()
        return value or None
    except Exception:
        return None


def _path(name):
    return os.path.join(CACHE_DIR, name)


def _write_json(name, data):
    try:
        os.makedirs(CACHE_DIR, exist_ok=True)
        temporary = _path(f"{name}.tmp-{os.getpid()}-{threading.get_ident()}")
        with open(temporary, "w", encoding="utf-8") as handle:
            json.dump(data, handle)
        os.replace(temporary, _path(name))
    except Exception:
        pass


def _read_json(name):
    try:
        with open(_path(name), encoding="utf-8") as handle:
            return json.load(handle)
    except Exception:
        return None


def _key(url, authorized):
    return hashlib.sha256(f"{url}|{int(bool(authorized))}".encode()).hexdigest()[:40] + ".json"


def _limited_until():
    data = _read_json(LIMIT_FILE) or {}
    try:
        reset = float(data.get("reset") or 0)
    except Exception:
        return 0.0
    return reset if reset > time.time() else 0.0


def rate_limit_message(reset=None):
    reset = reset or _limited_until()
    when = time.strftime("%H:%M", time.localtime(reset)) if reset else "later"
    return f"GitHub rate limit reached until {when}; add a GitHub token to raise it"


def _response(entry, url):
    headers = email.message.Message()
    for key, value in (entry.get("headers") or {}).items():
        headers[key] = value
    body = base64.b64decode(entry.get("body") or "")
    return urllib.response.addinfourl(io.BytesIO(body), headers, url, 200)


def _is_rate_limited(error):
    if error.code not in (403, 429):
        return False
    headers = error.headers or {}
    if str(headers.get("X-RateLimit-Remaining", "")) == "0" or error.code == 429:
        return True
    try:
        body = error.read().decode("utf-8", "replace").lower()
    except Exception:
        body = ""
    return "rate limit" in body


def _record_limit(error):
    headers = error.headers or {}
    try:
        reset = float(headers.get("X-RateLimit-Reset") or 0)
    except Exception:
        reset = 0
    if reset <= time.time():
        retry = headers.get("Retry-After")
        reset = time.time() + (float(retry) if str(retry or "").isdigit() else 900)
    _write_json(LIMIT_FILE, {"reset": reset})
    return reset


def _rate_limit_error(url, reset):
    return urllib.error.HTTPError(url, 403, rate_limit_message(reset), email.message.Message(), io.BytesIO(b""))


def cached_urlopen(request, *args, **kwargs):
    """urlopen() replacement: caches GitHub API GETs, passes all else."""
    url = request.full_url if isinstance(request, urllib.request.Request) else str(request)
    method = request.get_method() if isinstance(request, urllib.request.Request) else "GET"
    if method != "GET" or (urlsplit(url).hostname or "").lower() != "api.github.com":
        return _original_urlopen(request, *args, **kwargs)

    token = _token()
    name = _key(url, token)
    entry = _read_json(name)
    now = time.time()

    if entry and now - float(entry.get("time") or 0) < TTL:
        return _response(entry, url)

    reset = _limited_until()
    if reset and not token:
        if entry:
            return _response(entry, url)  # stale beats nothing while limited
        raise _rate_limit_error(url, reset)

    if isinstance(request, urllib.request.Request):
        outgoing = urllib.request.Request(
            url, headers=dict(request.header_items()), method="GET"
        )
    else:
        outgoing = urllib.request.Request(url, method="GET")
    if not outgoing.has_header("User-agent"):
        outgoing.add_header("User-Agent", "BUA-Updater")
    if token:
        outgoing.add_header("Authorization", f"Bearer {token}")
    if entry and entry.get("etag"):
        outgoing.add_header("If-None-Match", entry["etag"])

    try:
        with _original_urlopen(outgoing, *args, **kwargs) as response:
            body = response.read(MAX_BODY + 1)
            if len(body) > MAX_BODY:
                raise urllib.error.URLError("GitHub API response too large")
            keep = {k: v for k, v in response.headers.items()
                    if k.lower() in ("content-type", "etag", "last-modified", "link")}
            entry = {
                "time": time.time(),
                "etag": response.headers.get("ETag"),
                "headers": keep,
                "body": base64.b64encode(body).decode("ascii"),
            }
            with _lock:
                _write_json(name, entry)
            return _response(entry, url)
    except urllib.error.HTTPError as error:
        if error.code == 304 and entry:
            entry["time"] = time.time()
            with _lock:
                _write_json(name, entry)
            return _response(entry, url)
        if _is_rate_limited(error):
            reset = _record_limit(error)
            if entry:
                return _response(entry, url)
            raise _rate_limit_error(url, reset) from None
        raise


def install():
    """Route urllib.request.urlopen through the cache (idempotent)."""
    global _original_urlopen
    if getattr(urllib.request.urlopen, "_bua_github_cache", False):
        return
    _original_urlopen = urllib.request.urlopen
    cached_urlopen._bua_github_cache = True
    urllib.request.urlopen = cached_urlopen
