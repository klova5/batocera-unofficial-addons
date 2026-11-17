"""BUA updater package: the Updater screen and everything behind it.

Loaded by bua_installerx86.py (load_updater_package) into its own module
namespace when the package is installed in
/userdata/system/add-ons/bua/updater. It replaces UpdaterScreen, and
registers the install hooks BUA_HOOKS defines. Without the package BUA
runs exactly as before.

Shipped in the bua-updater-x86_64.tar.gz release asset, which
install_x86_new.sh downloads and checks against a pinned SHA256.
"""

import shlex

from urllib.parse import urlparse, urlsplit


from pathlib import Path


# Route the updater's GitHub API requests through its shared cache, which
# also stops calling GitHub once the rate limit is reached
# (BUA_GITHUB_API_CACHE_V1).
try:
    sys.path.append("/userdata/system/add-ons/bua/updater/catalog")
    import bua_github_api as _bua_github_api

    _bua_github_api.install()
except Exception:
    _bua_github_api = None


# Safe display initialization that never corrupts the Batocera framebuffer
def init_display():
    global screen, W, H, UI_SCALE

    # Windowed mode for development/testing if needed
    if os.environ.get("BUA_WINDOWED"):
        size = (1280, 720)
        screen = pygame.display.set_mode(size, pygame.RESIZABLE)
    else:
        # Use native resolution (matches working display.py approach)
        display_info = pygame.display.Info()
        screen_width = display_info.current_w
        screen_height = display_info.current_h
        # Borderless, anchored at the top-left: a plain window gets a
        # title bar from the window manager, which pushes a screen-sized
        # window down so its bottom (the button hints) is cut off.
        # NOFRAME covers the screen without changing the video mode;
        # BUA_FULLSCREEN=1 asks for real fullscreen instead.
        os.environ.setdefault("SDL_VIDEO_WINDOW_POS", "0,0")
        flags = pygame.FULLSCREEN if os.environ.get("BUA_FULLSCREEN") == "1" else pygame.NOFRAME
        screen = pygame.display.set_mode((screen_width, screen_height), flags)

    W, H = screen.get_size()
    UI_SCALE = max(1.0, min(W / 1280.0, H / 720.0))


# ------------------------------
# BUA Package State Manager
# ------------------------------
#
# bua_history.json remains the human-readable installation history.
# This separate file stores the machine-readable package state used
# for reliable update detection.
#
# Schema:
#
# {
#   "_schema": 1,
#   "packages": {
#       "Lutris": {
#           "package_revision": "...",
#           "app_version": "...",
#           "installer_source": "...",
#           "update_method": "reinstall",
#           "installed_at": "...",
#           "updated_at": "..."
#       }
#   }
# }
#
PACKAGE_STATE_FILE = os.environ.get(
    "BUA_PACKAGE_STATE_FILE",
    "/userdata/system/add-ons/bua_packages.json"
)


PACKAGE_STATE_SCHEMA = 1


BLOCKED_SOURCE_FILE = (
    "/userdata/system/add-ons/bua/updater/catalog/global/"
    "blocked-source-packages.json"
)


_BLOCKED_SOURCE_CACHE = None


def load_blocked_source_packages() -> Dict:
    """
    Load packages whose required functional upstream/integration source
    is currently unavailable.

    Failure to read this optional manifest must never break the updater.
    """
    global _BLOCKED_SOURCE_CACHE

    if _BLOCKED_SOURCE_CACHE is not None:
        return _BLOCKED_SOURCE_CACHE

    result = {}

    try:
        with open(
            BLOCKED_SOURCE_FILE,
            "r",
            encoding="utf-8",
        ) as f:
            data = json.load(f)

        packages = data.get("packages")

        if isinstance(packages, dict):
            for app_name, info in packages.items():
                if not isinstance(app_name, str):
                    continue

                if not isinstance(info, dict):
                    continue

                if info.get("status") != "blocked_source":
                    continue

                result[app_name] = {
                    "status": "blocked_source",
                    "reason": str(
                        info.get("reason") or ""
                    ).strip(),
                    "source": str(
                        info.get("source") or ""
                    ).strip(),
                }

    except Exception as exc:
        print(
            "[BUA] Could not load blocked-source manifest: "
            f"{exc}"
        )

    _BLOCKED_SOURCE_CACHE = result
    return result


def get_blocked_source_status(app_name: str) -> Dict | None:
    """
    Return blocker metadata for a known broken-source package.
    """
    info = load_blocked_source_packages().get(app_name)

    if not info:
        return None

    return {
        "status": "blocked_source",
        "needs_update": False,
        "reason": info.get("reason") or "",
        "source": info.get("source") or "",
    }


def load_package_state() -> Dict:
    """Load BUA machine-readable installed-package state."""
    default_state = {
        "_schema": PACKAGE_STATE_SCHEMA,
        "packages": {}
    }

    try:
        if not os.path.exists(PACKAGE_STATE_FILE):
            return default_state

        with open(PACKAGE_STATE_FILE, "r") as f:
            state = json.load(f)

        if not isinstance(state, dict):
            return default_state

        if not isinstance(state.get("packages"), dict):
            state["packages"] = {}

        state["_schema"] = PACKAGE_STATE_SCHEMA
        return state

    except Exception as e:
        print(f"Error loading package state: {e}")
        return default_state


def save_package_state(state: Dict):
    """Atomically save BUA machine-readable installed-package state."""
    try:
        os.makedirs(os.path.dirname(PACKAGE_STATE_FILE), exist_ok=True)

        state["_schema"] = PACKAGE_STATE_SCHEMA
        state.setdefault("packages", {})

        temp_file = PACKAGE_STATE_FILE + ".tmp"

        with open(temp_file, "w") as f:
            json.dump(state, f, indent=2, sort_keys=True)

        os.replace(temp_file, PACKAGE_STATE_FILE)

    except Exception as e:
        print(f"Error saving package state: {e}")


BUA_REGISTRATION_PREFIX = "__BUA_REGISTER__="


def extract_install_registration(lines: List[str]) -> Dict | None:
    """
    Extract installer-provided BUA package metadata from captured output.

    Installers may emit one line:

      __BUA_REGISTER__={...json...}

    The newest valid registration line wins.
    """
    if not lines:
        return None

    for raw_line in reversed(lines):
        line = str(raw_line).strip()

        if not line.startswith(BUA_REGISTRATION_PREFIX):
            continue

        payload = line[len(BUA_REGISTRATION_PREFIX):].strip()

        try:
            registration = json.loads(payload)
        except Exception as e:
            print(f"[BUA] Invalid installer registration JSON: {e}")
            continue

        if isinstance(registration, dict):
            return registration

    return None


def normalize_install_registration(registration: Dict) -> Dict:
    """
    Validate and normalize installer-provided package metadata.

    Unknown fields are deliberately ignored so installers cannot write
    arbitrary package-state keys.
    """
    if not isinstance(registration, dict):
        return {}

    normalized = {}

    app_version = registration.get("app_version")

    if app_version is not None:
        app_version = str(app_version).strip()

        if app_version:
            normalized["app_version"] = app_version

    update_identity = registration.get("update_identity")

    if update_identity is not None:
        update_identity = str(update_identity).strip()

    # Backward compatibility:
    # schema-1 installers did not have a separate update identity.
    if not update_identity:
        update_identity = normalized.get("app_version")

    if update_identity:
        normalized["update_identity"] = update_identity

    # Optional variant identifier for installers that expose multiple
    # independently updateable upstream variants under one BUA entry.
    #
    # Examples:
    #   blissos16-generic
    #   blissos16-go
    #
    # Keep this deliberately restrictive because it may later be passed
    # back to registration-only installer probes.
    variant_id = registration.get("variant_id")

    if variant_id is not None:
        variant_id = str(variant_id).strip()

        if (
            variant_id
            and re.fullmatch(
                r"[A-Za-z0-9._-]{1,64}",
                variant_id,
            )
        ):
            normalized["variant_id"] = variant_id

    update_method = registration.get("update_method")

    if update_method in (
        "reinstall",
        "custom",
        "unsupported",
    ):
        normalized["update_method"] = update_method

    upstream = registration.get("upstream")

    if isinstance(upstream, dict):
        upstream_type = upstream.get("type")

        if upstream_type:
            clean_upstream = {
                "type": str(upstream_type).strip()
            }

            for key in (
                "owner",
                "repo",
                "url",
                "channel",
                "asset",
            ):
                value = upstream.get(key)

                if value is not None:
                    value = str(value).strip()

                    if value:
                        clean_upstream[key] = value

            normalized["upstream"] = clean_upstream

    update_recipe = registration.get("update_recipe")

    if isinstance(update_recipe, dict):
        recipe_type = str(
            update_recipe.get("type") or ""
        ).strip()

        if recipe_type in (
            "replace_file",
            "replace_archive",
            "replace_bundle",
            "multi_component",
        ):
            clean_recipe = {
                "type": recipe_type,
            }

            for key in (
                "target",
                "asset_pattern",
                "asset_exclude_pattern",
                "download_url",
                "archive_subpath",
            ):
                value = update_recipe.get(key)

                if value is not None:
                    value = str(value).strip()

                    if value:
                        clean_recipe[key] = value

            executable = update_recipe.get("executable")

            if isinstance(executable, bool):
                clean_recipe["executable"] = executable

            if recipe_type == "multi_component":
                components = update_recipe.get("components")

                if isinstance(components, list):
                    clean_components = []

                    for component in components:
                        if not isinstance(component, dict):
                            continue

                        url = str(
                            component.get("url") or ""
                        ).strip()

                        target = str(
                            component.get("target") or ""
                        ).strip()

                        if (
                            not url
                            or not target.startswith("/userdata/")
                        ):
                            continue

                        clean_component = {
                            "type": str(
                                component.get("type")
                                or "replace_file"
                            ).strip(),
                            "url": url,
                            "target": target,
                            "executable": bool(
                                component.get(
                                    "executable",
                                    True,
                                )
                            ),
                        }

                        name = str(
                            component.get("name") or ""
                        ).strip()

                        version = str(
                            component.get("version") or ""
                        ).strip()

                        if name:
                            clean_component["name"] = name

                        if version:
                            clean_component["version"] = version

                        clean_components.append(
                            clean_component
                        )

                    if clean_components:
                        clean_recipe["components"] = (
                            clean_components
                        )

            normalized["update_recipe"] = clean_recipe

    version_probe = registration.get("version_probe")

    if isinstance(version_probe, dict):
        probe_type = version_probe.get("type")

        if probe_type:
            clean_probe = {
                "type": str(probe_type).strip()
            }

            for key in (
                "path",
                "key",
                "command",
                "pattern",
            ):
                value = version_probe.get(key)

                if value is not None:
                    value = str(value).strip()

                    if value:
                        clean_probe[key] = value

            normalized["version_probe"] = clean_probe

    return normalized


def apply_install_registration(
    app_name: str,
    runner_lines: List[str],
    registration_source: str = "installer",
) -> bool:
    """
    Save package metadata emitted by a successful BUA installer.
    """
    registration = extract_install_registration(runner_lines)

    if not registration:
        return False

    package_data = normalize_install_registration(registration)

    if not package_data:
        return False

    package_data["registration_source"] = registration_source
    package_data["registration_schema"] = 2

    set_package_state(app_name, package_data)

    print(
        f"[BUA] Registered install metadata for "
        f"{app_name}: {package_data}"
    )

    return True


def get_bua_registration_shell_helper() -> str:
    """Return the shell helper injected into BUA installers."""
    return r"""
# GitHub API requests from python3 helpers go through the updater's cache
# (BUA_GITHUB_API_CACHE_V1).
if [ -d /userdata/system/add-ons/bua/updater/catalog/pyhooks ]; then
    export PYTHONPATH="/userdata/system/add-ons/bua/updater/catalog/pyhooks${PYTHONPATH:+:$PYTHONPATH}"
fi
bua_register() {
    local app_version="$1"
    local upstream_type="$2"
    local owner="$3"
    local repo="$4"
    local update_method="$5"
    local probe_type="$6"
    local probe_path="$7"
    local probe_key="$8"
    local update_identity="${9:-$app_version}"
    local variant_id="${10:-}"
    local probe_command="${11:-}"
    local probe_pattern="${12:-}"
    local update_type="${13:-}"
    local update_target="${14:-}"
    local asset_pattern="${15:-}"
    local update_download_url="${16:-}"
    local update_executable="${17:-}"
    local upstream_url="${18:-}"
    local components_json="${19:-}"

    python3 - \
        "$app_version" \
        "$upstream_type" \
        "$owner" \
        "$repo" \
        "$update_method" \
        "$probe_type" \
        "$probe_path" \
        "$probe_key" \
        "$update_identity" \
        "$variant_id" \
        "$probe_command" \
        "$probe_pattern" \
        "$update_type" \
        "$update_target" \
        "$asset_pattern" \
        "$update_download_url" \
        "$update_executable" \
        "$upstream_url" \
        "$components_json" <<'PYBUAREG'
import json
import sys

(
    app_version,
    upstream_type,
    owner,
    repo,
    update_method,
    probe_type,
    probe_path,
    probe_key,
    update_identity,
    variant_id,
    probe_command,
    probe_pattern,
    update_type,
    update_target,
    asset_pattern,
    update_download_url,
    update_executable,
    upstream_url,
    components_json,
) = sys.argv[1:20]

registration = {
    "app_version": app_version,
    "update_identity": update_identity or app_version,
    "upstream": {
        "type": upstream_type,
    },
    "update_method": update_method,
}

if variant_id:
    registration["variant_id"] = variant_id

if update_type:
    registration["update_recipe"] = {
        "type": update_type,
    }

    if update_target:
        registration["update_recipe"]["target"] = update_target

    if asset_pattern:
        registration["update_recipe"]["asset_pattern"] = asset_pattern

    if update_download_url:
        registration["update_recipe"]["download_url"] = update_download_url

    if update_executable:
        registration["update_recipe"]["executable"] = (
            update_executable.lower()
            in ("1", "true", "yes")
        )

    if components_json:
        components = json.loads(components_json)

        if not isinstance(components, list):
            raise SystemExit(
                "components_json must contain a list"
            )

        registration["update_recipe"]["components"] = components

if owner:
    registration["upstream"]["owner"] = owner

if repo:
    registration["upstream"]["repo"] = repo

if upstream_url:
    registration["upstream"]["url"] = upstream_url

if probe_type:
    registration["version_probe"] = {
        "type": probe_type,
    }

    if probe_path:
        registration["version_probe"]["path"] = probe_path

    if probe_key:
        registration["version_probe"]["key"] = probe_key

    if probe_command:
        registration["version_probe"]["command"] = probe_command

    if probe_pattern:
        registration["version_probe"]["pattern"] = probe_pattern

import os
line = "__BUA_REGISTER__=" + json.dumps(registration, separators=(",", ":"))
target = os.environ.get("BUA_REGISTRATION_FILE")
if target:
    with open(target, "a", encoding="utf-8") as fh:
        fh.write(line + "\n")
else:
    print(line)
PYBUAREG
}
export -f bua_register
"""


def get_package_state(app_name: str) -> Dict:
    """Return saved package metadata for one app."""
    state = load_package_state()
    package = state.get("packages", {}).get(app_name, {})

    if isinstance(package, dict):
        return package

    return {}


def set_package_state(app_name: str, package_data: Dict):
    """Create or replace package metadata for one installed BUA app."""
    state = load_package_state()
    packages = state.setdefault("packages", {})

    existing = packages.get(app_name, {})
    if not isinstance(existing, dict):
        existing = {}

    merged = dict(existing)
    merged.update(package_data)

    if "installed_at" not in merged:
        merged["installed_at"] = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

    merged["updated_at"] = datetime.now().strftime("%Y-%m-%d %H:%M:%S")

    packages[app_name] = merged
    save_package_state(state)


def remove_package_state(app_name: str):
    """Remove package metadata after a BUA-managed uninstall."""
    state = load_package_state()
    packages = state.setdefault("packages", {})

    if app_name in packages:
        del packages[app_name]
        save_package_state(state)


def get_installer_source_url(install_cmd: str) -> str | None:
    """Extract the primary HTTP(S) installer URL from a BUA install command."""
    if not install_cmd:
        return None

    match = re.search(r'https?://[^\s\'"]+', install_cmd)
    if not match:
        return None

    return match.group(0)


def fetch_remote_bytes(url: str, timeout: int = 20) -> bytes | None:
    """Download raw remote content used to calculate a BUA package revision."""
    if not url:
        return None

    try:
        req = urllib.request.Request(
            url,
            headers={
                "User-Agent": "BUA-Installer",
                "Cache-Control": "no-cache",
            }
        )

        with urllib.request.urlopen(req, timeout=timeout) as response:
            return response.read()

    except Exception as e:
        print(f"Error fetching package source {url}: {e}")
        return None


def calculate_package_revision_from_bytes(data: bytes) -> str | None:
    """Return deterministic SHA-256 revision for package source content."""
    if data is None:
        return None

    import hashlib
    return hashlib.sha256(data).hexdigest()


def get_remote_package_revision(app_name: str) -> Dict:
    """
    Calculate the current BUA package revision for one app.

    Returns:
        {
            "source": "...",
            "revision": "...",
            "supported": True/False,
            "error": None/"..."
        }
    """
    cmd = APPS.get(app_name, "")
    source_url = get_installer_source_url(cmd)

    result = {
        "source": source_url,
        "revision": None,
        "supported": False,
        "error": None,
    }

    if not source_url:
        result["error"] = "No HTTP installer source"
        return result

    data = fetch_remote_bytes(source_url)

    if data is None:
        result["error"] = "Unable to download installer source"
        return result

    revision = calculate_package_revision_from_bytes(data)

    if not revision:
        result["error"] = "Unable to calculate package revision"
        return result

    result["revision"] = revision
    result["supported"] = True
    return result


def record_current_package_revision(
    app_name: str,
    update_method: str = "reinstall",
    app_version: str | None = None
) -> bool:
    """
    Record the currently published BUA package revision as the installed baseline.

    This does NOT install or update the app. It only records package metadata.
    """
    remote = get_remote_package_revision(app_name)

    if not remote.get("supported"):
        return False

    package_data = {
        "package_revision": remote["revision"],
        "installer_source": remote["source"],
        "update_method": update_method,
    }

    if app_version:
        package_data["app_version"] = app_version

    set_package_state(app_name, package_data)
    return True


def get_github_commit_at_or_before(
    owner: str,
    repo: str,
    branch: str,
    path: str,
    date_str: str
) -> Dict:
    """
    Find the newest GitHub commit touching `path` at or before a local
    BUA installation timestamp.

    Returns:
        {
            "sha": "...",
            "committed_at": "...",
            "error": None/"..."
        }
    """
    result = {
        "sha": None,
        "committed_at": None,
        "error": None,
    }

    try:
        # BUA history timestamps are written in the Batocera machine's
        # local timezone. Convert that local time to UTC for GitHub.
        local_dt = datetime.strptime(date_str, "%Y-%m-%d %H:%M:%S")
        utc_dt = local_dt.astimezone(timezone.utc)
        until = utc_dt.strftime("%Y-%m-%dT%H:%M:%SZ")

        import urllib.parse

        query = urllib.parse.urlencode({
            "path": path,
            "sha": branch,
            "until": until,
            "per_page": 1,
        })

        api_url = (
            f"https://api.github.com/repos/{owner}/{repo}/commits?"
            + query
        )

        req = urllib.request.Request(
            api_url,
            headers={
                "User-Agent": "BUA-Installer",
                "Accept": "application/vnd.github+json",
            }
        )

        with urllib.request.urlopen(req, timeout=20) as response:
            commits = json.loads(response.read().decode("utf-8"))

        if not isinstance(commits, list) or not commits:
            result["error"] = "No historical commit found"
            return result

        commit = commits[0]
        sha = commit.get("sha")

        committed_at = (
            commit.get("commit", {})
                  .get("committer", {})
                  .get("date")
        )

        if not sha:
            result["error"] = "Historical commit has no SHA"
            return result

        result["sha"] = sha
        result["committed_at"] = committed_at
        return result

    except Exception as e:
        result["error"] = str(e)
        return result


def get_historical_package_revision(
    app_name: str,
    install_date: str
) -> Dict:
    """
    Reconstruct the BUA installer revision that existed when an app
    was last successfully installed.
    """
    result = {
        "app": app_name,
        "install_date": install_date,
        "source": None,
        "commit_sha": None,
        "committed_at": None,
        "revision": None,
        "supported": False,
        "error": None,
    }

    cmd = APPS.get(app_name, "")
    parsed = parse_github_raw_url(cmd)

    if not parsed:
        result["error"] = "Installer is not a supported GitHub raw source"
        return result

    owner, repo, branch, path = parsed

    commit = get_github_commit_at_or_before(
        owner,
        repo,
        branch,
        path,
        install_date
    )

    if not commit.get("sha"):
        result["error"] = commit.get("error") or "Historical commit not found"
        return result

    sha = commit["sha"]

    historical_url = (
        f"https://raw.githubusercontent.com/"
        f"{owner}/{repo}/{sha}/{path}"
    )

    data = fetch_remote_bytes(historical_url)

    if data is None:
        result["error"] = "Unable to download historical installer"
        return result

    revision = calculate_package_revision_from_bytes(data)

    if not revision:
        result["error"] = "Unable to hash historical installer"
        return result

    result.update({
        "source": historical_url,
        "commit_sha": sha,
        "committed_at": commit.get("committed_at"),
        "revision": revision,
        "supported": True,
    })

    return result


def migrate_package_state_from_history(
    app_name: str,
    update_method: str | None = None
) -> Dict:
    """
    Create package-state metadata for an existing pre-updater BUA install.

    The historical installer revision is reconstructed from the app's
    last successful BUA installation date. Existing tracked packages
    are never overwritten.
    """
    existing = get_package_state(app_name)

    if existing.get("package_revision"):
        return {
            "status": "already_tracked",
            "app": app_name,
            "package": existing,
            "error": None,
        }

    install_date = get_last_install_date(app_name)

    if not install_date:
        return {
            "status": "no_history",
            "app": app_name,
            "package": {},
            "error": "No successful BUA installation history",
        }

    historical = get_historical_package_revision(
        app_name,
        install_date
    )

    if not historical.get("supported"):
        return {
            "status": "unsupported",
            "app": app_name,
            "package": {},
            "error": historical.get("error"),
        }

    cmd = APPS.get(app_name, "")
    current_source = get_installer_source_url(cmd)

    if update_method is None:
        update_method = get_update_method(app_name)

    package_data = {
        "package_revision": historical["revision"],
        "installer_source": current_source,
        "installed_commit_sha": historical.get("commit_sha"),
        "installed_commit_date": historical.get("committed_at"),
        "installed_at": install_date,
        "baseline_method": "historical_bua_history",
        "update_method": update_method,
    }

    set_package_state(app_name, package_data)

    return {
        "status": "migrated",
        "app": app_name,
        "package": package_data,
        "error": None,
    }


REGISTRATION_SNAPSHOT_CACHE: Dict[str, Dict] = {}


def _build_dev_registration_adapters() -> Dict[str, str]:
    import json

    base = Path("/userdata/system/add-ons/bua/updater")
    converted = base / "converted"
    manifest_path = (
        base
        / "catalog/global/global-update-manifest.json"
    )

    priority = {
        "vendor-api": 10,
        "vendor-web": 20,
        "sourceforge": 30,
        "itch": 40,
        "codeberg": 45,
        "special-parents": 50,
        "github-filtered": 60,
        "trusted-github-parents": 70,
        "github-web-parents": 80,
        "github-release-api": 90,
        "github-release-download": 100,
        "flathub": 105,
        "web-wrappers": 110,
        "variant-packages": 115,
        "integration-packages": 120,
    }

    def norm(value: str) -> str:
        return re.sub(
            r"[^a-z0-9]+",
            "",
            str(value).lower(),
        )

    try:
        manifest = json.loads(
            manifest_path.read_text(
                encoding="utf-8",
            )
        )
    except Exception:
        return {}

    scripts = []

    for path in converted.rglob("*.sh"):
        try:
            script_text = path.read_text(
                encoding="utf-8",
                errors="ignore",
            )
        except Exception:
            continue

        if "BUA_REGISTRATION_ONLY" not in script_text:
            continue

        rel = path.relative_to(converted)
        family = rel.parts[0]

        scripts.append({
            "path": str(path),
            "family": family,
            "score": priority.get(family, 999),
            "keys": {
                norm(path.stem),
                norm(path.parent.name),
            },
        })

    result: Dict[str, str] = {}

    for entry in manifest.get("apps", []):
        app = str(entry.get("app") or "").strip()

        if not app:
            continue

        keys = {norm(app)}

        installer_path = str(
            entry.get("installer_path") or ""
        ).strip()

        if installer_path:
            ip = Path(installer_path)
            keys.add(norm(ip.stem))
            keys.add(norm(ip.parent.name))

        hits = [
            item
            for item in scripts
            if keys & item["keys"]
        ]

        if app == "Wine Dependencies x86":
            hits = [
                item
                for item in hits
                if "dependencies32" in item["path"]
            ]

        elif app == "Wine Dependencies x64":
            hits = [
                item
                for item in hits
                if "dependencies64" in item["path"]
            ]

        if not hits:
            continue

        hits.sort(
            key=lambda item: (
                item["score"],
                item["path"],
            )
        )

        result[app] = hits[0]["path"]

    return result


DEV_REGISTRATION_ADAPTERS: Dict[str, str] = (
    _build_dev_registration_adapters()
)


DEV_REGISTRATION_ADAPTERS["Wine Manager"] = (
    "/userdata/system/add-ons/bua/updater/converted/"
    "integration-packages/wine-manager/061-Wine_Manager.sh"
)


def get_dev_registration_adapter(app_name: str) -> str | None:
    path = DEV_REGISTRATION_ADAPTERS.get(app_name)

    if not path:
        return None

    if not os.path.isfile(path):
        return None

    return path


def get_global_manifest_entry(app_name: str) -> Dict | None:
    """
    Return the canonical global-manifest entry for one live BUA app.
    """
    manifest_path = Path(
        "/userdata/system/add-ons/bua/updater/catalog/global/"
        "global-update-manifest.json"
    )

    try:
        payload = json.loads(
            manifest_path.read_text(
                encoding="utf-8"
            )
        )
    except Exception:
        return None

    items = payload.get("apps", [])

    if not isinstance(items, list):
        return None

    # Preferred join: exact live catalog app name.
    for item in items:
        if (
            isinstance(item, dict)
            and item.get("app") == app_name
        ):
            return item

    return None


def _generic_payload_url_from_manifest(
    entry: Dict
) -> str | None:
    """
    Select the most likely actual application payload URL from
    one canonical manifest entry.

    This deliberately ignores artwork, localhost reload hooks,
    and the BUA installer itself.
    """
    if not isinstance(entry, dict):
        return None

    installer_url = str(
        entry.get("installer_url")
        or ""
    ).strip()

    candidates = []

    for key in (
        "external_urls",
        "all_urls",
    ):
        values = entry.get(key) or []

        if not isinstance(values, list):
            continue

        for value in values:
            url = str(value or "").strip()

            if not url:
                continue

            if url in candidates:
                continue

            candidates.append(url)

    def score(url: str):
        lower = url.lower()

        if (
            "127.0.0.1" in lower
            or "localhost" in lower
        ):
            return -10000

        if (
            installer_url
            and url == installer_url
        ):
            return -10000

        path = lower.split("?", 1)[0]

        # Only real downloads count (BUA_PAYLOAD_URL_RULES_V1): never an
        # API endpoint, an XML/schema namespace, a folder, plain HTTP, or
        # another BUA installer script.
        parsed = urlsplit(url)
        host = (parsed.hostname or "").lower()
        last = path.rstrip("/").rsplit("/", 1)[-1]
        if (
            parsed.scheme != "https"
            or host.startswith("api.")
            or host in ("www.w3.org", "w3.org", "schemas.xmlsoap.org")
            or path.endswith("/")
            or path.endswith(".sh")
        ):
            return -10000

        # Artwork and metadata are not application payloads.
        if path.endswith((
            ".png",
            ".jpg",
            ".jpeg",
            ".gif",
            ".webp",
            ".svg",
            ".ico",
            ".xml",
        )):
            return -10000

        value = 0

        payload_suffixes = (
            ".appimage",
            ".wsquashfs",
            ".squashfs",
            ".zip",
            ".7z",
            ".tar.gz",
            ".tgz",
            ".tar.xz",
            ".txz",
            ".tar.bz2",
            ".tbz2",
            ".exe",
            ".msi",
            ".deb",
            ".rpm",
        )

        if path.endswith(payload_suffixes):
            value += 100

        if "/releases/download/" in lower:
            value += 80

        if "drive.usercontent.google.com/" in lower:
            value += 70

        if "sourceforge.net/" in lower:
            value += 60

        if url in (
            entry.get("external_urls")
            or []
        ):
            value += 20

        return value

    # A payload needs positive evidence: a payload file extension, a
    # release asset or a known file host (BUA_PAYLOAD_URL_RULES_V1).
    usable = [
        (score(url), url)
        for url in candidates
        if score(url) >= 60
    ]

    if not usable:
        return None

    usable.sort(
        key=lambda pair: pair[0],
        reverse=True,
    )

    return usable[0][1]


def _http_payload_identity(
    url: str
) -> Dict:
    """
    Derive a stable identity from remote payload metadata without
    downloading the complete application.

    Probe order:
      1. HEAD
      2. one-byte ranged GET

    The signed redirect destination is intentionally NOT included
    in the identity. Only the stable catalog payload URL is used.
    """
    import hashlib
    import email.utils

    result = {
        "supported": False,
        "url": url,
        "identity": None,
        "display_version": None,
        "etag": None,
        "last_modified": None,
        "size": None,
        "filename": None,
        "error": None,
    }

    def read_headers(method, ranged=False):
        headers = {
            "User-Agent":
                "BUA-Global-Updater/1",
            "Accept":
                "*/*",
        }

        if ranged:
            headers["Range"] = "bytes=0-0"

        req = urllib.request.Request(
            url,
            headers=headers,
            method=method,
        )

        with urllib.request.urlopen(
            req,
            timeout=30,
        ) as response:
            h = response.headers

            etag = (
                h.get("ETag")
                or ""
            ).strip()

            modified = (
                h.get("Last-Modified")
                or ""
            ).strip()

            disposition = (
                h.get("Content-Disposition")
                or ""
            ).strip()

            content_range = (
                h.get("Content-Range")
                or ""
            ).strip()

            length = (
                h.get("Content-Length")
                or ""
            ).strip()

            total_size = None

            if content_range:
                match = re.search(
                    r"/(\d+)\s*$",
                    content_range,
                )

                if match:
                    total_size = int(
                        match.group(1)
                    )

            if (
                total_size is None
                and length.isdigit()
            ):
                parsed_length = int(length)

                # Ignore zero-length HEAD oddities and the
                # one-byte body from our Range probe.
                if parsed_length > 1:
                    total_size = parsed_length

            filename = None

            if disposition:
                match = re.search(
                    r'filename\*?='
                    r'(?:UTF-8\'\')?'
                    r'"?([^";]+)',
                    disposition,
                    re.I,
                )

                if match:
                    filename = (
                        match.group(1)
                        .strip()
                        .strip('"')
                    )

            return {
                "etag": etag or None,
                "last_modified":
                    modified or None,
                "size": total_size,
                "filename": filename,
            }

    metadata = None

    try:
        metadata = read_headers(
            "HEAD",
            ranged=False,
        )
    except Exception:
        metadata = None

    def useful(m):
        if not isinstance(m, dict):
            return False

        return bool(
            m.get("etag")
            or m.get("last_modified")
            or m.get("size")
        )

    # Google Drive and some CDNs provide useful metadata only
    # when an actual byte range is requested.
    if not useful(metadata):
        try:
            metadata = read_headers(
                "GET",
                ranged=True,
            )
        except Exception as exc:
            result["error"] = str(exc)
            return result

    # Even when HEAD supplies only a weak size, a range request
    # may expose Last-Modified or Content-Range. Prefer the richer
    # result when possible.
    elif not (
        metadata.get("etag")
        or metadata.get("last_modified")
    ):
        try:
            ranged = read_headers(
                "GET",
                ranged=True,
            )

            if useful(ranged):
                metadata = ranged
        except Exception:
            pass

    if not useful(metadata):
        result["error"] = (
            "Payload server exposed no stable "
            "identity metadata"
        )
        return result

    etag = metadata.get("etag")
    modified = metadata.get(
        "last_modified"
    )
    size = metadata.get("size")
    filename = metadata.get(
        "filename"
    )

    # At minimum require something stronger than URL alone.
    if not (
        etag
        or modified
        or size
    ):
        result["error"] = (
            "Payload identity metadata incomplete"
        )
        return result

    identity_material = {
        "url": url,
        "etag": etag,
        "last_modified": modified,
        "size": size,
        "filename": filename,
    }

    encoded = json.dumps(
        identity_material,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")

    digest = hashlib.sha256(
        encoded
    ).hexdigest()

    # Human-readable display value. This is deliberately
    # called a payload version rather than pretending it is
    # an upstream semantic application version.
    display_version = None

    if modified:
        try:
            dt = email.utils.parsedate_to_datetime(
                modified
            )

            display_version = (
                "payload@"
                + dt.strftime("%Y-%m-%d")
            )
        except Exception:
            display_version = (
                "payload@"
                + modified
            )

    if not display_version:
        display_version = (
            "payload@"
            + digest[:12]
        )

    result.update({
        "supported": True,
        "identity":
            "payload:" + digest,
        "display_version":
            display_version,
        "etag": etag,
        "last_modified": modified,
        "size": size,
        "filename": filename,
        "error": None,
    })

    return result


def _bua_installer_identity_snapshot(app_name: str, entry: Dict, reason: str) -> Dict | None:
    """Last-resort latest identity: the app's own BUA installer
    (BUA_INSTALLER_IDENTITY_V1).

    For apps with no usable payload or upstream release info: the
    installer script's SHA-256, shown with its last-commit date from
    SCRIPT_DATES.md. It changes whenever BUA's maintainers update the
    installer, and the app is updated by running that installer again.
    """
    sha = str(entry.get("sha256") or "").strip().lower()
    if not re.fullmatch(r"[0-9a-f]{64}", sha) or entry.get("fetch_status") != "ok":
        return None
    path = str(entry.get("installer_path") or "").strip()
    stamp = ""
    try:
        stamp = str(get_script_dates().get(path) or "").split(" ", 1)[0]
    except Exception:
        stamp = ""
    version = "installer@" + (stamp if re.fullmatch(r"\d{4}-\d{2}-\d{2}", stamp) else sha[:12])
    return {
        "supported": True,
        "app": app_name,
        "source": entry.get("installer_url"),
        "registration": {
            "app_version": version,
            "update_identity": "installer:" + sha,
            "update_method": "reinstall",
            "upstream": {"type": "bua_installer", "url": entry.get("installer_url")},
            "update_recipe": {"type": "reinstall"},
        },
        "lines": [],
        "error": None,
        "fallback": "installer",
        "fallback_reason": reason,
    }


def get_reinstall_safety(app_name: str) -> Dict:
    """Would updating this app by re-running its installer reset its
    settings? (BUA_REINSTALL_SAFETY_V1)

    The global manifest records a verdict for every installer when it is
    built, so apps added to BUA later are covered too. Older manifests
    without it fall back to checking the cached installer here.
    """
    entry = get_global_manifest_entry(app_name) or {}
    found = entry.get("reinstall_safety")
    if isinstance(found, dict) and found.get("verdict") in ("keeps_settings", "may_reset", "unknown"):
        return found
    cached = str(entry.get("cached_installer") or "")
    try:
        import reinstall_safety as _rs

        text = Path(cached).read_text(encoding="utf-8", errors="replace")
        result = _rs.analyze(text)
        if result.get("nested") and result.get("verdict") == "keeps_settings":
            result["verdict"] = "unknown"
        return result
    except Exception:
        return {"verdict": "unknown", "paths": []}


def _bua_broken_download(error: str) -> bool:
    return bool(re.search(r"HTTP Error (404|410)\b", str(error or "")))


def get_generic_catalog_registration_snapshot(
    app_name: str
) -> Dict:
    """
    Generic install/update identity fallback for catalog apps that
    do not implement BUA_REGISTRATION_ONLY.

    It does not install or alter anything.
    """
    result = {
        "supported": False,
        "app": app_name,
        "source": None,
        "registration": None,
        "lines": [],
        "error": None,
    }

    entry = get_global_manifest_entry(
        app_name
    )

    if not entry:
        result["error"] = (
            "No global manifest entry"
        )
        return result

    payload_url = (
        _generic_payload_url_from_manifest(
            entry
        )
    )

    if not payload_url:
        fallback = _bua_installer_identity_snapshot(
            app_name, entry, "No application payload URL in its installer"
        )
        if fallback:
            return fallback
        result["error"] = (
            "No generic application payload URL "
            "could be resolved"
        )
        return result

    declared_checksums = (
        entry.get("declared_payload_sha256")
        or {}
    )

    checksum_identity = None

    if isinstance(
        declared_checksums,
        dict,
    ):
        import platform

        machine = platform.machine().lower()

        if machine in (
            "x86_64",
            "amd64",
        ):
            checksum_identity = (
                declared_checksums.get(
                    "x86_64"
                )
                or declared_checksums.get(
                    "generic"
                )
            )

        elif machine in (
            "aarch64",
            "arm64",
        ):
            checksum_identity = (
                declared_checksums.get(
                    "arm64"
                )
                or declared_checksums.get(
                    "generic"
                )
            )

        else:
            checksum_identity = (
                declared_checksums.get(
                    "generic"
                )
            )

    if checksum_identity:
        checksum_identity = str(
            checksum_identity
        ).lower().strip()

        identity = {
            "supported": True,
            "identity":
                "sha256:"
                + checksum_identity,
            "display_version":
                "sha256@"
                + checksum_identity[:12],
            "etag": None,
            "last_modified": None,
            "size": None,
            "filename": None,
            "error": None,
        }

    else:
        identity = _http_payload_identity(
            payload_url
        )

    if not identity.get("supported"):
        error = identity.get("error") or "Unable to identify payload"
        # A dead download link means the installer itself is broken:
        # say so instead of offering an update that cannot work.
        if _bua_broken_download(error):
            result["error"] = f"Download link is broken ({error}): {payload_url}"
            result["broken_source"] = True
            return result
        fallback = _bua_installer_identity_snapshot(app_name, entry, error)
        if fallback:
            return fallback
        result["error"] = error
        return result

    registration = {
        "app_version":
            identity["display_version"],
        "update_identity":
            identity["identity"],
        "update_method":
            "custom",
        "upstream": {
            "type":
                entry.get("source_family")
                or "generic_http",
            "owner":
                entry.get("github_owner"),
            "repo":
                entry.get("github_repo"),
            "url":
                payload_url,
        },
    }

    result.update({
        "supported": True,
        "source": payload_url,
        "registration": registration,
        "error": None,
    })

    return result


def get_catalog_registration_snapshot(
    app_name: str,
    use_cache: bool = True,
) -> Dict:
    """
    Ask the app's current BUA installer for its latest upstream identity
    without installing or modifying anything.

    The installer itself acts as the parent-source adapter.
    """
    if use_cache and app_name in REGISTRATION_SNAPSHOT_CACHE:
        return REGISTRATION_SNAPSHOT_CACHE[app_name]

    result_data = {
        "supported": False,
        "app": app_name,
        "source": None,
        "registration": None,
        "lines": [],
        "error": None,
    }

    install_cmd = APPS.get(app_name)

    if not install_cmd:
        result_data["error"] = "No installer command"
        return result_data

    source_url = get_installer_source_url(
        install_cmd
    )

    dev_adapter = get_dev_registration_adapter(
        app_name
    )

    if dev_adapter:
        result_data["source"] = dev_adapter

        try:
            installer_text = Path(
                dev_adapter
            ).read_text(
                encoding="utf-8",
                errors="ignore",
            )
        except Exception as exc:
            result_data["error"] = (
                "Could not read dev registration adapter: "
                f"{exc}"
            )
            return result_data

    else:
        result_data["source"] = source_url

        if not source_url:
            result_data["error"] = (
                "Installer source is not registration-compatible"
            )
            return result_data

        try:
            installer_bytes = fetch_remote_bytes(
                source_url
            )
        except Exception as exc:
            result_data["error"] = str(exc)
            return result_data

        if not installer_bytes:
            result_data["error"] = "Installer source was empty"
            return result_data

        if isinstance(installer_bytes, bytes):
            installer_text = installer_bytes.decode(
                "utf-8",
                "ignore",
            )
        else:
            installer_text = str(installer_bytes)

    # Never execute an installer as an update probe unless it has
    # explicitly opted into the metadata-only contract.
    if "BUA_REGISTRATION_ONLY" not in installer_text:
        generic = get_generic_catalog_registration_snapshot(
            app_name
        )

        if generic.get("supported"):
            if use_cache:
                REGISTRATION_SNAPSHOT_CACHE[
                    app_name
                ] = generic

            return generic

        result_data["error"] = (
            generic.get("error")
            or
            "Installer does not advertise "
            "registration-only support"
        )

        if use_cache:
            REGISTRATION_SNAPSHOT_CACHE[
                app_name
            ] = result_data

        return result_data

    helper = get_bua_registration_shell_helper()

    installed_package = (
        get_package_state(app_name)
        or {}
    )

    installed_variant = str(
        installed_package.get("variant_id")
        or ""
    ).strip()

    # Package-state variant IDs were normalized on write, but validate
    # again before placing one into a shell environment.
    if not re.fullmatch(
        r"[A-Za-z0-9._-]{0,64}",
        installed_variant,
    ):
        installed_variant = ""

    script = (
        helper
        + "\n"
        + "export BUA_REGISTRATION_ONLY=1\n"
        + (
            "export BUA_INSTALLED_VARIANT='"
            + installed_variant
            + "'\n"
        )
        + installer_text
        + "\n"
    )

    try:
        process = subprocess.run(
            ["bash"],
            input=script,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=45,
        )
    except Exception as exc:
        result_data["error"] = str(exc)
        return result_data

    lines = process.stdout.splitlines()
    result_data["lines"] = lines

    if process.returncode != 0:
        detail = ""
        for line in reversed(lines):
            line = line.strip()
            if line and not line.startswith(BUA_REGISTRATION_PREFIX):
                detail = line[:160]
                break
        result_data["error"] = (
            f"Registration-only mode exited "
            f"{process.returncode}"
            + (f": {detail}" if detail else "")
        )

        return result_data

    registration = extract_install_registration(
        lines
    )

    if not registration:
        result_data["error"] = (
            "Installer emitted no registration metadata"
        )
        return result_data

    normalized = normalize_install_registration(
        registration
    )

    if not normalized:
        result_data["error"] = (
            "Installer emitted invalid registration metadata"
        )
        return result_data

    if not normalized.get("app_version"):
        result_data["error"] = (
            "Installer registration has no app_version"
        )
        return result_data

    # Converted integration adapters may only describe the
    # BUA-packaged integration artifact rather than the real
    # upstream application payload. Those are not valid parent-
    # source identities for the global updater.
    upstream = normalized.get("upstream") or {}

    upstream_type = str(
        upstream.get("type") or ""
    ).strip().lower()

    upstream_owner = str(
        upstream.get("owner") or ""
    ).strip().lower()

    if (
        upstream_type == "integration_asset"
        or upstream_owner == "bua"
    ):
        generic = get_generic_catalog_registration_snapshot(
            app_name
        )

        if generic.get("supported"):
            if use_cache:
                REGISTRATION_SNAPSHOT_CACHE[
                    app_name
                ] = generic

            return generic

    result_data.update({
        "supported": True,
        "registration": normalized,
        "error": None,
    })

    if use_cache:
        REGISTRATION_SNAPSHOT_CACHE[app_name] = result_data

    return result_data


def migrate_registered_metadata(app_name: str) -> bool:
    """
    Adopt safe updater metadata for an existing BUA install.

    Important:
    A registration-only snapshot describes the CURRENT upstream release,
    not necessarily the version already installed locally.

    Therefore adoption may copy source/probe/policy metadata, but it must
    never stamp the latest upstream app_version or update_identity onto an
    existing installation unless the local installed identity is known.
    """
    package = get_package_state(app_name)

    if not package:
        return False

    snapshot = get_catalog_registration_snapshot(
        app_name
    )

    if not snapshot.get("supported"):
        return False

    registration = (
        snapshot.get("registration") or {}
    )

    adopted = {}

    upstream = registration.get("upstream")

    if isinstance(upstream, dict) and upstream:
        adopted["upstream"] = upstream

    version_probe = registration.get("version_probe")

    if isinstance(version_probe, dict) and version_probe:
        adopted["version_probe"] = version_probe

    update_method = registration.get("update_method")

    if update_method in (
        "reinstall",
        "custom",
        "unsupported",
    ):
        adopted["update_method"] = update_method

    if not adopted:
        return False

    adopted["registration_source"] = "installer"
    adopted["registration_schema"] = 2

    # Only retain an installed identity that already existed.
    # Never manufacture it from the latest upstream snapshot.
    if package.get("app_version"):
        adopted["app_version"] = package["app_version"]

    if package.get("update_identity"):
        adopted["update_identity"] = package["update_identity"]

    set_package_state(
        app_name,
        adopted,
    )

    print(
        f"[BUA] Adopted updater metadata for "
        f"{app_name} without changing installed identity"
    )

    return True


def ensure_package_tracking(app_name: str) -> Dict:
    """
    Ensure an existing BUA install has package revision metadata
    and, where supported, upstream application registration metadata.

    Safe to call repeatedly.
    """
    existing = get_package_state(app_name)

    if not existing.get("package_revision"):
        result = migrate_package_state_from_history(app_name)

        if result.get("status") not in ("tracked", "migrated"):
            return result

        existing = get_package_state(app_name)

    if existing and not existing.get("upstream"):
        migrate_registered_metadata(app_name)
        existing = get_package_state(app_name)

    return {
        "status": "tracked",
        "app": app_name,
        "package": existing,
        "error": None,
    }


def package_update_status(app_name: str) -> Dict:
    """
    Compare saved installed BUA revision against the currently published revision.

    Status values:
        untracked
        current
        update_available
        unsupported
        error
    """
    installed = get_package_state(app_name)
    remote = get_remote_package_revision(app_name)

    if not remote.get("supported"):
        return {
            "status": "unsupported",
            "needs_update": False,
            "installed_revision": installed.get("package_revision"),
            "remote_revision": None,
            "source": remote.get("source"),
            "error": remote.get("error"),
        }

    installed_revision = installed.get("package_revision")
    remote_revision = remote.get("revision")

    if not installed_revision:
        status = "untracked"
        needs_update = False
    elif installed_revision != remote_revision:
        status = "update_available"
        needs_update = True
    else:
        status = "current"
        needs_update = False

    return {
        "status": status,
        "needs_update": needs_update,
        "installed_revision": installed_revision,
        "remote_revision": remote_revision,
        "source": remote.get("source"),
        "error": None,
    }


def read_json_key(path: str, key: str) -> str | None:
    """Read one top-level value from a JSON file."""
    try:
        with open(path, "r") as f:
            data = json.load(f)

        value = data.get(key)

        if value is None:
            return None

        return str(value).strip()

    except Exception as e:
        print(f"[BUA] Version read error for {path}: {e}")
        return None


def read_version_probe(probe: Dict) -> str | None:
    """Read an installed application version using registered probe metadata."""
    if not isinstance(probe, dict):
        return None

    probe_type = probe.get("type")

    if probe_type == "json":
        return read_json_key(
            probe.get("path", ""),
            probe.get("key", "")
        )

    if probe_type == "command":
        command = probe.get("command")

        if not command:
            return None

        try:
            result = subprocess.run(
                command,
                shell=True,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                timeout=20,
            )

            if result.returncode != 0:
                return None

            output = result.stdout.strip()

            match = re.search(
                probe.get("pattern", r"(.+)"),
                output,
            )

            if not match:
                return None

            return match.group(1).strip()

        except Exception:
            return None

    return None


def get_registered_version_metadata(app_name: str) -> Dict:
    """Return installer-registered update/version metadata."""
    package = get_package_state(app_name)

    return {
        "app_version": package.get("app_version"),
        "update_identity": (
            package.get("update_identity")
            or package.get("app_version")
        ),
        "upstream": package.get("upstream"),
        "version_probe": package.get("version_probe"),
        "registration_source": package.get("registration_source"),
        "registration_schema": package.get("registration_schema"),
    }


def get_installed_app_version(app_name: str) -> str | None:
    """
    Return the actual installed app version when possible.

    Prefer the registered local probe. Fall back to the version BUA
    recorded when the installer completed.
    """
    registered = get_registered_version_metadata(app_name)

    probe = registered.get("version_probe")

    if isinstance(probe, dict):
        probed = read_version_probe(probe)

        if probed:
            return probed

    recorded = registered.get("app_version")

    if recorded:
        return str(recorded).strip()

    return None


def get_latest_github_release_version(
    owner: str,
    repo: str
) -> str | None:
    """Return tag_name from the repository's latest GitHub release."""
    try:
        api_url = (
            f"https://api.github.com/repos/"
            f"{owner}/{repo}/releases/latest"
        )

        req = urllib.request.Request(
            api_url,
            headers={
                "User-Agent": "BUA-Installer",
                "Accept": "application/vnd.github+json",
                "Cache-Control": "no-cache",
            }
        )

        with urllib.request.urlopen(req, timeout=20) as response:
            release = json.loads(
                response.read().decode("utf-8")
            )

        tag = release.get("tag_name")

        if not tag:
            return None

        return str(tag).strip()

    except Exception as e:
        print(
            f"[BUA] GitHub release version error "
            f"for {owner}/{repo}: {e}"
        )
        return None


def get_latest_version_from_upstream(upstream: Dict) -> str | None:
    """Resolve latest app version from registered upstream metadata."""
    if not isinstance(upstream, dict):
        return None

    upstream_type = upstream.get("type")

    if upstream_type == "github_release":
        owner = upstream.get("owner")
        repo = upstream.get("repo")

        if not owner or not repo:
            return None

        return get_latest_github_release_version(
            str(owner),
            str(repo)
        )

    return None


def get_latest_app_version(app_name: str) -> str | None:
    """Return latest upstream version from installer registration."""
    registered = get_registered_version_metadata(app_name)

    upstream = registered.get("upstream")

    if not isinstance(upstream, dict):
        return None

    return get_latest_version_from_upstream(upstream)


def resolve_parent_update_asset(app_name: str) -> Dict:
    """
    Resolve the latest application payload directly from its parent source.

    This does not run the BUA installer.
    """
    import fnmatch

    result = {
        "supported": False,
        "url": None,
        "target": None,
        "executable": False,
        "registration": None,
        "recipe": None,
        "error": None,
    }

    snapshot = get_catalog_registration_snapshot(
        app_name,
        use_cache=False,
    )

    if not snapshot.get("supported"):
        result["error"] = snapshot.get("error")
        return result

    registration = snapshot.get("registration") or {}

    # Execution metadata comes from the canonical global recipe
    # registry. Parent/source identity continues to come live from
    # the registration adapter.
    recipe = {}

    recipe_manifest = Path(
        "/userdata/system/add-ons/bua/updater/catalog/global/"
        "app-update-recipes.json"
    )

    try:
        recipe_data = json.loads(
            recipe_manifest.read_text(
                encoding="utf-8",
            )
        )

        canonical = (
            recipe_data.get("apps", {})
            .get(app_name, {})
        )

        if isinstance(canonical, dict):
            canonical_type = str(
                canonical.get("update_type") or ""
            ).strip()

            if canonical_type:
                recipe["type"] = canonical_type

            for key in (
                "target",
                "asset_pattern",
                "asset_exclude_pattern",
                "download_url",
                "archive_subpath",
                "archive_format",
                "executable",
            ):
                if key in canonical:
                    recipe[key] = canonical[key]

            bundle_members = canonical.get("bundle_members")
            if isinstance(bundle_members, list):
                recipe["bundle_members"] = bundle_members

            components = canonical.get("components")
            if isinstance(components, list):
                recipe["components"] = components

    except Exception as exc:
        result["error"] = (
            "Could not read global update recipe: "
            f"{exc}"
        )
        return result

    # A future adapter may provide additional live recipe metadata.
    # Merge it over the canonical defaults.
    adapter_recipe = registration.get("update_recipe")

    if isinstance(adapter_recipe, dict):
        recipe.update(adapter_recipe)

    if not recipe:
        result["error"] = "No parent-source update recipe"
        return result

    if recipe.get("type") not in (
        "replace_file",
        "replace_archive",
        "replace_bundle",
        "multi_component",
    ):
        result["error"] = (
            "Unsupported update recipe: "
            + str(recipe.get("type") or "")
        )
        return result

    target = str(recipe.get("target") or "").strip()

    if not target.startswith("/userdata/"):
        result["error"] = "Unsafe or missing update target"
        return result

    if recipe.get("type") == "multi_component":
        components = recipe.get("components") or []

        if not isinstance(components, list) or not components:
            result["error"] = "multi_component has no components"
            return result

        for index, component in enumerate(components):
            if not isinstance(component, dict):
                result["error"] = (
                    f"Invalid multi_component entry {index + 1}"
                )
                return result

            component_type = str(
                component.get("type") or "replace_file"
            ).strip()

            if component_type != "replace_file":
                result["error"] = (
                    "Unsupported multi_component member type: "
                    + component_type
                )
                return result

            component_url = str(
                component.get("url") or ""
            ).strip()

            component_target = str(
                component.get("target") or ""
            ).strip()

            if not component_url:
                result["error"] = (
                    f"Component {index + 1} has no URL"
                )
                return result

            if not component_target.startswith("/userdata/"):
                result["error"] = (
                    f"Component {index + 1} has unsafe target"
                )
                return result

        result.update({
            "supported": True,
            "url": "",
            "target": target,
            "executable": False,
            "registration": registration,
            "recipe": recipe,
        })

        return result

    download_url = str(
        recipe.get("download_url") or ""
    ).strip()

    upstream = registration.get("upstream") or {}

    # Any registration adapter may expose the current resolved parent
    # payload directly. This is source-family agnostic.
    if not download_url:
        download_url = str(
            upstream.get("url") or ""
        ).strip()

    if not download_url:
        if upstream.get("type") != "github_release":
            result["error"] = (
                "Update recipe requires a resolved parent payload URL "
                "or GitHub release metadata"
            )
            return result

        owner = str(upstream.get("owner") or "").strip()
        repo = str(upstream.get("repo") or "").strip()
        pattern = str(
            recipe.get("asset_pattern") or ""
        ).strip()

        exclude_pattern = str(
            recipe.get("asset_exclude_pattern") or ""
        ).strip()

        if not owner or not repo or not pattern:
            result["error"] = "Incomplete GitHub update recipe"
            return result

        try:
            api_url = (
                f"https://api.github.com/repos/"
                f"{owner}/{repo}/releases/latest"
            )

            req = urllib.request.Request(
                api_url,
                headers={
                    "User-Agent": "BUA-Installer",
                    "Accept": "application/vnd.github+json",
                    "Cache-Control": "no-cache",
                },
            )

            with urllib.request.urlopen(
                req,
                timeout=20,
            ) as response:
                release = json.loads(
                    response.read().decode("utf-8")
                )

            for asset in release.get("assets") or []:
                name = str(asset.get("name") or "")
                url = str(
                    asset.get("browser_download_url") or ""
                )

                if not (
                    name
                    and url
                    and fnmatch.fnmatch(name, pattern)
                ):
                    continue

                if (
                    exclude_pattern
                    and fnmatch.fnmatch(
                        name,
                        exclude_pattern,
                    )
                ):
                    continue

                download_url = url
                break

        except Exception as exc:
            result["error"] = (
                f"Parent release lookup failed: {exc}"
            )
            return result

    if not download_url:
        result["error"] = "No matching parent release asset"
        return result

    result.update({
        "supported": True,
        "url": download_url,
        "target": target,
        "executable": bool(
            recipe.get("executable", False)
        ),
        "registration": registration,
        "recipe": recipe,
    })

    return result


BUA_SCANNED_RELEASES={}


def _bua_release_fingerprint(status):
    if not isinstance(status,dict):return None
    if status.get("status")!="update_available" or status.get("needs_update") is not True:return None
    return (status.get("latest_source"),status.get("latest_version"),status.get("latest_update_identity"))


SWITCH_APP_NAME = "Switch"


_SWITCH_CATALOG_DIR = "/userdata/system/add-ons/bua/updater/catalog"


_SWITCH_LATEST_CACHE = {}


# A scan resolves the release once; binding the update right after the
# scan reuses it. Queueing later always re-resolves.
_SWITCH_LATEST_TTL = 120


def _bua_load_switch_binding():
    """Load the bundled, integrity-verified Switch binding module."""
    import importlib.util

    if "module" in _SWITCH_LATEST_CACHE:
        return _SWITCH_LATEST_CACHE["module"]

    path = os.path.join(_SWITCH_CATALOG_DIR, "switch_component_binding.py")

    if not os.path.isfile(path) or os.path.islink(path):
        return None

    spec = importlib.util.spec_from_file_location(
        "bua_switch_component_binding", path
    )
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)

    if not hasattr(module, "verify_installed_components"):
        return None

    _SWITCH_LATEST_CACHE["module"] = module
    return module


def _bua_switch_latest(binding, expected_identity=None,
                       expected_display=None, use_cache=False):
    """Resolve and validate the latest Switch component release set."""
    cached = _SWITCH_LATEST_CACHE.get("latest")

    if (
        use_cache
        and cached
        and time.monotonic() - cached[0] < _SWITCH_LATEST_TTL
    ):
        latest = cached[1]
    else:
        script = os.path.join(_SWITCH_CATALOG_DIR, "switch_identity.py")

        if not os.path.isfile(script) or os.path.islink(script):
            raise RuntimeError("Switch identity resolver missing")

        result = subprocess.run(
            [sys.executable or "python3", "-I", script],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=180,
        )

        if result.returncode != 0:
            reason = (result.stderr or "").strip().splitlines()
            raise RuntimeError(
                reason[-1] if reason else "Switch release lookup failed"
            )

        lines = [
            line.strip()
            for line in result.stdout.splitlines()
            if line.strip()
        ][-5:]

        match = re.fullmatch(
            r"switch:(\d+):components:[0-9a-f]{64}",
            lines[1] if len(lines) == 5 else "",
        )

        if not match:
            raise RuntimeError("Unexpected Switch identity output")

        latest = binding.verify_switch_components(
            lines,
            major=int(match.group(1)),
            architecture="x86_64",
        )
        _SWITCH_LATEST_CACHE["latest"] = (time.monotonic(), latest)

    if expected_identity is not None and latest["identity"] != expected_identity:
        raise RuntimeError("Switch identity changed since selection; rescan")

    if expected_display is not None and latest["display_version"] != expected_display:
        raise RuntimeError("Switch version changed since selection; rescan")

    return latest


def _bua_record_switch_baseline(app_name, latest):
    """Record a Switch identity proven by byte-for-byte file matches."""
    set_package_state(app_name, {
        "app_version": latest["display_version"],
        "update_identity": latest["identity"],
        "update_method": "custom",
        "upstream": {"type": "multi_parent"},
        "update_recipe": {
            "type": "multi_component",
            "target": "/userdata/system/switch/appimages",
            "components": [
                c for c in latest["components"]
                if not c.get("unavailable")
            ],
        },
        "registration_source": "verified_component_match",
        "registration_schema": 2,
    })


def get_switch_version_status(app_name: str) -> Dict | None:
    """
    Switch status from per-component file verification.

    Returns None when the bundled binding module is unavailable, so the
    generic path is used instead.
    """
    binding = _bua_load_switch_binding()

    if binding is None:
        return None

    metadata = get_registered_version_metadata(app_name)
    registered_version = metadata.get("app_version")
    installed_identity = (
        metadata.get("update_identity") or registered_version
    )

    status = {
        "status": "unknown",
        "needs_update": False,
        "installed_version": registered_version,
        "latest_version": None,
        "latest_source": None,
        "installed_update_identity": installed_identity,
        "latest_update_identity": None,
        "registered_version": registered_version,
        "probe_version": None,
        "registration_mismatch": False,
        "component_states": [],
        "component_summary": "",
        "error": None,
    }

    try:
        latest = _bua_switch_latest(binding)
    except Exception as exc:
        status["error"] = f"Switch release check failed: {exc}"
        return status

    status.update({
        "latest_version": latest["display_version"],
        "latest_source": "bua",
        "latest_update_identity": latest["identity"],
    })

    states = binding.verify_installed_components(latest["components"])
    status["component_states"] = states

    errors = [s for s in states if s["state"] == "error"]
    differs = [s for s in states if s["state"] == "differs"]
    matched = [s for s in states if s["state"] == "match"]
    missing = [s for s in states if s["state"] == "missing"]
    unavailable = [s for s in states if s["state"] == "unavailable"]

    if errors:
        status["error"] = "; ".join(
            f"{s['name']}: {s['detail']}" for s in errors
        )
        return status

    if not (differs or matched):
        status["error"] = (
            "; ".join(
                tr("switch_component_unavailable", "{name} source unavailable ({reason})",
                   name=s["name"], reason=s["detail"])
                for s in unavailable
            )
            or "No Switch emulators found in appimages"
        )
        return status

    summary = [
        tr("switch_component_out_of_date", "{name} out of date", name=s["name"])
        for s in differs
    ]
    summary += [
        tr("switch_component_unavailable", "{name} source unavailable ({reason})",
           name=s["name"], reason=s["detail"])
        for s in unavailable
    ]
    summary += [
        tr("switch_component_not_installed", "{name} not installed", name=s["name"])
        for s in missing
    ]
    status["component_summary"] = ", ".join(summary)

    # Components the user never installed are reported, never added.
    # An unavailable source can be neither confirmed nor updated: the
    # rest are still checked, but Switch is not reported up to date.
    if not differs and unavailable:
        status["error"] = (
            tr("switch_other_components_current", "Other emulators up to date")
            + "; "
            + status["component_summary"]
        )
        return status

    if not differs:
        if installed_identity != latest["identity"] and not missing:
            _bua_record_switch_baseline(app_name, latest)
            status["installed_update_identity"] = latest["identity"]

        status.update({
            "status": "current",
            "installed_version": latest["display_version"],
        })
        return status

    status.update({
        "status": "update_available",
        "needs_update": True,
        "installed_version": (
            None
            if registered_version == latest["display_version"]
            else registered_version
        ),
    })
    return status


def _bua_bind_switch_components(app, selection, resolved):
    """Bind a Switch update to the selected, freshly re-verified release.

    Only components whose installed files differ are replaced.
    """
    if app != SWITCH_APP_NAME:
        return None, "Multi-component updates are only defined for Switch"

    binding = _bua_load_switch_binding()

    if binding is None:
        return None, "Switch verification module unavailable"

    try:
        latest = _bua_switch_latest(
            binding,
            expected_identity=selection.get("latest_update_identity"),
            expected_display=selection.get("latest_version"),
            use_cache=True,
        )
    except Exception as exc:
        return None, str(exc)

    registration = resolved.get("registration") or {}

    if (
        registration.get("app_version") != latest["display_version"]
        or registration.get("update_identity") != latest["identity"]
    ):
        return None, "Switch registration does not match verified release"

    states = {
        s["name"]: s["state"]
        for s in binding.verify_installed_components(latest["components"])
    }

    if any(state == "error" for state in states.values()):
        return None, "Switch component verification failed; rescan"

    pending = [
        component
        for component in latest["components"]
        if states.get(component["name"]) == "differs"
    ]

    if not pending:
        return None, "Switch is already up to date"

    recipe = dict(resolved.get("recipe") or {})
    recipe["type"] = "multi_component"
    recipe["components"] = pending

    bound = dict(resolved)
    bound["recipe"] = recipe
    bound["target"] = "/userdata/system/switch/appimages"

    return bound, None


def _bua_bind_selected_payload(app,selection):
    """Reject resolution of a different software asset than the selected one."""
    from urllib.parse import urlsplit,unquote
    import re,fnmatch
    if _bua_release_fingerprint(selection) is None:return None,"No selected release"
    source=selection.get("latest_source")
    version=selection.get("latest_version")
    if source not in ("bua","parent") or not isinstance(version,str) or not version.strip():
        return None,"Missing selected source/version"
    resolved=resolve_parent_update_asset(app)
    if not isinstance(resolved,dict) or not resolved.get("supported"):
        return None,(resolved.get("error") if isinstance(resolved,dict) else None) or "No supported payload recipe"
    recipe=resolved.get("recipe") or {}
    registration=resolved.get("registration") or {}
    if not isinstance(recipe,dict) or not isinstance(registration,dict):return None,"Invalid recipe or registration"
    # Switch is preserved, but its five separate independent releases must
    # each be verified before a global version can authorize replacement.
    if recipe.get("type")=="multi_component":return _bua_bind_switch_components(app,selection,resolved)
    if recipe.get("type") not in ("replace_file","replace_archive","replace_bundle"):
        return None,"Unsupported payload recipe"
    target=resolved.get("target")
    if not isinstance(target,str) or not target.startswith("/userdata/"):
        return None,"Unexpected update target"
    url=resolved.get("url")
    if not isinstance(url,str):return None,"Missing resolved asset URL"
    u=urlsplit(url)
    if u.scheme!="https" or not u.hostname or u.username or u.password:
        return None,"Insecure payload URL"
    if source=="bua":
        current_version=registration.get("app_version")
        identity=registration.get("update_identity") or current_version
        if current_version!=version or identity!=selection.get("latest_update_identity"):
            return None,"BUA release/version/identity no longer matches selection"
        upstream=registration.get("upstream") or {}
        explicit=registration.get("update_recipe") or {}
        if not isinstance(explicit,dict):explicit={}
        direct=(url==explicit.get("download_url") or url==upstream.get("url")) if isinstance(upstream,dict) else False
    else:
        upstream=get_registered_version_metadata(app).get("upstream") or {}
        direct=False
    if not isinstance(upstream,dict):return None,"Invalid upstream metadata"
    if upstream.get("type")=="github_release":
        owner,repo=upstream.get("owner"),upstream.get("repo")
        if not (isinstance(owner,str) and isinstance(repo,str)
                and re.fullmatch(r"[A-Za-z0-9-]{1,39}",owner)
                and re.fullmatch(r"[A-Za-z0-9_.-]{1,100}",repo)
                and ".." not in repo):return None,"Invalid GitHub owner/repository"
        parts=[unquote(p) for p in u.path.split("/") if p]
        if any(p in (".","..") or "/" in p or "\\" in p for p in parts):
            return None,"Unsafe release URL path"
        matched=(u.hostname=="github.com" and u.port in (None,443)
                 and len(parts)==6 and parts[0:4]==[owner,repo,"releases","download"]
                 and parts[4]==version and bool(parts[5]) and not u.query and not u.fragment)
        if not matched and not (source=="bua" and direct):
            return None,"Payload does not match selected release tag/repository"
        if source=="parent":
            pattern=recipe.get("asset_pattern")
            if not isinstance(pattern,str) or not pattern or not fnmatch.fnmatch(parts[5],pattern):
                return None,"Developer payload does not match asset pattern"
            exclude=recipe.get("asset_exclude_pattern")
            if isinstance(exclude,str) and exclude and fnmatch.fnmatch(parts[5],exclude):
                return None,"Excluded developer asset"
    elif not (source=="bua" and direct):
        return None,"Source-specific payload proof unavailable"
    return resolved,None


# How each app's update will run, set when its command is built
# (BUA_UPDATE_METHODS_V1): "payload", "flatpak" or "reinstall".
UPDATE_METHODS: Dict[str, str] = {}


# Errors that mean "scan again", never "use another update method".
_UPDATE_NO_FALLBACK = (
    "rescan",
    "changed since selection",
    "No selected release",
    "Missing selected source",
)


def _flatpak_app_id(identity) -> str | None:
    match = re.fullmatch(r"flathub:([A-Za-z0-9._-]+):[^:]*:[0-9a-f]+", str(identity or ""))
    return match.group(1) if match else None


def _flatpak_installed_identity(app_id: str, branch: str = "") -> str | None:
    """flathub:<id>:<branch>:<commit> of the installed Flatpak, or None."""
    for scope in ("--system", "--user"):
        try:
            result = subprocess.run(
                ["flatpak", "info", scope, "--show-commit", app_id],
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, timeout=20,
            )
        except Exception:
            return None
        commit = (result.stdout or "").strip().splitlines()[-1:] if result.returncode == 0 else []
        if commit and re.fullmatch(r"[0-9a-f]{20,}", commit[0].strip()):
            return f"flathub:{app_id}:{branch or 'stable'}:{commit[0].strip()}"
    return None


def _bua_registration_marker(app_name: str, selected_status: Dict) -> str | None:
    """The registration an update records once it succeeds: the release
    that was scanned."""
    snapshot = get_catalog_registration_snapshot(app_name)
    registration = dict((snapshot.get("registration") or {}) if snapshot.get("supported") else {})
    if not registration or (
        registration.get("update_identity") or registration.get("app_version")
    ) != selected_status.get("latest_update_identity"):
        return None
    return "__BUA_REGISTER__=" + json.dumps(registration, sort_keys=True, separators=(",", ":"))


def _flatpak_update_command(app_name: str, selected_status: Dict) -> tuple[str | None, str | None]:
    import shlex

    app_id = _flatpak_app_id(selected_status.get("latest_update_identity"))
    if not app_id:
        return None, "Not a Flathub release"
    marker = _bua_registration_marker(app_name, selected_status)
    if not marker:
        return None, "Flathub release changed since selection; rescan"
    q_id = shlex.quote(app_id)
    command = (
        "BUA_PARENT_UPDATE=1; "
        f"if flatpak info --system {q_id} >/dev/null 2>&1; then scope=--system; else scope=--user; fi; "
        f"echo \"[BUA] Updating {app_id} from Flathub\"; "
        f"flatpak update -y --noninteractive $scope {q_id}; rc=$?; "
        f"if [ $rc -eq 0 ]; then {_bua_emit_shell(shlex.quote(marker))}; fi; exit $rc"
    )
    return command, None


def build_parent_update_command(
    app_name: str,
    selected_status: Dict | None = None,
) -> tuple[str | None, str | None]:
    """
    One update job for an app, by the best method available:

      1. Flathub apps: flatpak update of that app only.
      2. A complete payload recipe: replace only the app's payload,
         keeping its launchers, settings and integration.
      3. Otherwise: run the app's BUA installer again (reinstall), which
         the updater shows as such and asks to confirm.

    A release that changed since the scan never falls back: it needs a
    rescan.
    """
    status = selected_status or {}
    UPDATE_METHODS.pop(app_name, None)

    if status.get("installer_changed") and APPS.get(app_name):
        # The installer itself changed: only re-running it applies that.
        UPDATE_METHODS[app_name] = "reinstall"
        return APPS[app_name], None

    if _flatpak_app_id(status.get("latest_update_identity")):
        command, error = _flatpak_update_command(app_name, status)
        if command:
            UPDATE_METHODS[app_name] = "flatpak"
        return command, error

    command, error = _build_payload_update_command(app_name, selected_status)
    if command:
        UPDATE_METHODS[app_name] = "payload"
        return command, None
    if error and any(word in str(error) for word in _UPDATE_NO_FALLBACK):
        return None, error
    if _bua_release_fingerprint(status) is None:
        return None, error

    installer = APPS.get(app_name)
    if installer:
        UPDATE_METHODS[app_name] = "reinstall"
        return installer, None
    return None, error


def _build_payload_update_command(
    app_name: str,
    selected_status: Dict | None = None,
) -> tuple[str | None, str | None]:
    """
    Build one generic parent-source payload update job.

    This never reruns the original BUA installer; build_parent_update_command
    falls back to that when no payload recipe applies.
    """
    import shlex

    resolved, binding_error = _bua_bind_selected_payload(app_name, selected_status)
    if not resolved:
        return None, binding_error

    if not resolved.get("supported"):
        return None, resolved.get("error")

    registration = resolved["registration"]
    recipe = resolved.get("recipe") or {}

    recipe_type = str(
        recipe.get("type") or ""
    ).strip()

    url = resolved["url"]
    target = resolved["target"]

    marker = (
        "__BUA_REGISTER__="
        + json.dumps(
            registration,
            sort_keys=True,
            separators=(",", ":"),
        )
    )

    q_url = shlex.quote(url)
    q_target = shlex.quote(target)
    q_marker = shlex.quote(marker)

    if recipe_type == "multi_component":
        components = recipe.get("components") or []

        if not isinstance(components, list) or not components:
            return None, "multi_component has no components"

        clean_components = []

        for index, component in enumerate(components):
            if not isinstance(component, dict):
                return None, (
                    f"Invalid multi_component entry {index + 1}"
                )

            component_type = str(
                component.get("type") or "replace_file"
            ).strip()

            if component_type != "replace_file":
                return None, (
                    "Unsupported multi_component member type: "
                    + component_type
                )

            name = str(
                component.get("name")
                or f"component-{index + 1}"
            ).strip()

            component_url = str(
                component.get("url") or ""
            ).strip()

            component_target = str(
                component.get("target") or ""
            ).strip()

            if not component_url:
                return None, f"{name}: missing URL"

            if not component_target.startswith("/userdata/"):
                return None, f"{name}: unsafe target"

            clean_components.append({
                "name": name,
                "url": component_url,
                "target": component_target,
                "executable": bool(
                    component.get("executable", False)
                ),
            })

        parts = [
            "BUA_PARENT_UPDATE=1",
            "set -e",
            'WORK=$(mktemp -d /tmp/bua-multi-update.XXXXXX)',
            'trap \'rm -rf "$WORK"\' EXIT',
        ]

        # Stage every component before touching installed payloads.
        for index, component in enumerate(clean_components):
            q_name = shlex.quote(component["name"])
            q_component_url = shlex.quote(component["url"])
            staged = shlex.quote(
                f'$WORK/component-{index}'
            )

            # Keep $WORK expandable rather than shell-quoting it.
            staged = f'"$WORK/component-{index}"'

            parts.extend([
                f"echo '[BUA] Downloading {component['name']}'",
                (
                    "curl -fL --retry 3 -o "
                    f"{staged} {q_component_url}"
                ),
                f"test -s {staged}",
            ])

            if component["executable"]:
                parts.append(f"chmod +x {staged}")

        # Back up all currently installed component files.
        for index, component in enumerate(clean_components):
            q_target_component = shlex.quote(
                component["target"]
            )

            parts.extend([
                f"TARGET_{index}={q_target_component}",
                (
                    f'OLD_{index}="${{TARGET_{index}}}'
                    '.bua-old.$$"'
                ),
                (
                    f'mkdir -p "$(dirname '
                    f'"${{TARGET_{index}}}")"'
                ),
                f'rm -f "$OLD_{index}"',
                (
                    f'if [ -e "${{TARGET_{index}}}" ]; then '
                    f'mv "${{TARGET_{index}}}" "$OLD_{index}"; '
                    "fi"
                ),
            ])

        # Install every staged component.
        parts.append("FAILED=0")

        for index, component in enumerate(clean_components):
            parts.append(
                f'if ! mv "$WORK/component-{index}" '
                f'"${{TARGET_{index}}}"; then '
                "FAILED=1; "
                "fi"
            )

        # Roll everything back if any component failed.
        rollback = []

        for index, component in enumerate(clean_components):
            if index == 0:
                rollback.append(
                    f'if [ "$FAILED" -ne 0 ]; then '
                    f'rm -f "${{TARGET_{index}}}"'
                )
            else:
                rollback.append(
                    f'rm -f "${{TARGET_{index}}}"'
                )

            rollback.append(
                f'if [ -e "$OLD_{index}" ]; then '
                f'mv "$OLD_{index}" '
                f'"${{TARGET_{index}}}"; fi'
            )

        rollback.extend([
            "exit 1",
            "fi",
        ])

        parts.extend(rollback)

        # Commit successful transaction.
        for index, component in enumerate(clean_components):
            parts.append(f'rm -f "$OLD_{index}"')

        parts.extend([
            "trap - EXIT",
            'rm -rf "$WORK"',
            f"{_bua_emit_shell(q_marker)}",
        ])

        return "; ".join(parts), None

    if recipe_type == "replace_file":
        chmod_step = ""

        if resolved.get("executable"):
            chmod_step = 'chmod +x "$TMP"; '

        command = (
            "BUA_PARENT_UPDATE=1; "
            "set -e; "
            f"TARGET={q_target}; "
            'TMP="${TARGET}.bua-update.$$"; '
            'trap \'rm -f "$TMP"\' EXIT; '
            'mkdir -p "$(dirname "$TARGET")"; '
            f"echo '[BUA] Downloading newest {app_name} payload'; "
            f'curl -fL --retry 3 -o "$TMP" {q_url}; '
            'test -s "$TMP"; '
            + chmod_step
            + 'mv -f "$TMP" "$TARGET"; '
            'trap - EXIT; '
            f"{_bua_emit_shell(q_marker)}"
        )

        return command, None

    if recipe_type == "replace_archive":
        archive_subpath = str(
            recipe.get("archive_subpath") or ""
        ).strip()

        archive_format = str(
            recipe.get("archive_format") or ""
        ).strip().lower()

        q_subpath = shlex.quote(archive_subpath)
        q_archive_format = shlex.quote(archive_format)

        command = (
            "BUA_PARENT_UPDATE=1; "
            "set -e; "
            f"TARGET={q_target}; "
            f"URL={q_url}; "
            f"SUBPATH={q_subpath}; "
            f"ARCHIVE_FORMAT={q_archive_format}; "
            'WORK=$(mktemp -d /tmp/bua-update.XXXXXX); '
            'ARCHIVE="$WORK/payload"; '
            'EXTRACT="$WORK/extract"; '
            'mkdir -p "$EXTRACT"; '
            'trap \'rm -rf "$WORK"\' EXIT; '
            f"echo '[BUA] Downloading newest {app_name} payload'; "
            'curl -fL --retry 3 -o "$ARCHIVE" "$URL"; '
            'test -s "$ARCHIVE"; '
            'case "$ARCHIVE_FORMAT" in '
            'bsdtar) bsdtar -xf "$ARCHIVE" -C "$EXTRACT" ;; '
            'zip) unzip -oq "$ARCHIVE" -d "$EXTRACT" ;; '
            'tar) tar -xf "$ARCHIVE" -C "$EXTRACT" ;; '
            '"") '
            'case "$URL" in '
            '*.zip*) unzip -oq "$ARCHIVE" -d "$EXTRACT" ;; '
            '*.tar.gz*|*.tgz*|*.tar.xz*|*.txz*|*.tar.bz2*|*.tbz2*) '
            'tar -xf "$ARCHIVE" -C "$EXTRACT" ;; '
            '*) echo "[BUA] Unsupported archive format: $URL"; exit 1 ;; '
            'esac ;; '
            '*) echo "[BUA] Unsupported archive extractor: $ARCHIVE_FORMAT"; exit 1 ;; '
            'esac; '
            'SOURCE="$EXTRACT"; '
            'if [ -n "$SUBPATH" ]; then SOURCE="$EXTRACT/$SUBPATH"; fi; '
            'test -e "$SOURCE"; '
            'NEW="${TARGET}.bua-new.$$"; '
            'OLD="${TARGET}.bua-old.$$"; '
            'rm -rf "$NEW" "$OLD"; '
            'mv "$SOURCE" "$NEW"; '
            'if [ -e "$TARGET" ]; then mv "$TARGET" "$OLD"; fi; '
            'if mv "$NEW" "$TARGET"; then '
            '  rm -rf "$OLD"; '
            'else '
            '  rm -rf "$NEW"; '
            '  if [ -e "$OLD" ]; then mv "$OLD" "$TARGET"; fi; '
            '  exit 1; '
            'fi; '
            'trap - EXIT; '
            'rm -rf "$WORK"; '
            f"{_bua_emit_shell(q_marker)}"
        )

        return command, None

    if recipe_type == "replace_bundle":
        members = recipe.get("bundle_members") or []

        if not isinstance(members, list) or not members:
            return None, "replace_bundle has no bundle members"

        archive_subpath = str(
            recipe.get("archive_subpath") or ""
        ).strip()

        archive_format = str(
            recipe.get("archive_format") or ""
        ).strip().lower()

        clean_members = []

        for member in members:
            member = str(member or "").strip()

            if (
                not member
                or "/" in member
                or member in (".", "..")
            ):
                return None, (
                    "Unsafe replace_bundle member: "
                    + repr(member)
                )

            clean_members.append(member)

        member_words = " ".join(
            shlex.quote(member)
            for member in clean_members
        )

        q_subpath = shlex.quote(archive_subpath)
        q_archive_format = shlex.quote(archive_format)

        chmod_step = ""

        if resolved.get("executable"):
            chmod_step = 'chmod +x "$NEW"; '

        command = (
            "BUA_PARENT_UPDATE=1; "
            "set -e; "
            f"TARGET={q_target}; "
            f"URL={q_url}; "
            f"MEMBERS=({member_words}); "
            f"SUBPATH={q_subpath}; "
            f"ARCHIVE_FORMAT={q_archive_format}; "
            'WORK=$(mktemp -d /tmp/bua-update.XXXXXX); '
            'ARCHIVE="$WORK/payload"; '
            'EXTRACT="$WORK/extract"; '
            'mkdir -p "$EXTRACT" "$TARGET"; '
            'trap \'rm -rf "$WORK"\' EXIT; '
            f"echo '[BUA] Downloading newest {app_name} payload'; "
            'curl -fL --retry 3 -o "$ARCHIVE" "$URL"; '
            'test -s "$ARCHIVE"; '
            'if [ "$ARCHIVE_FORMAT" = "squashfs" ]; then '
            '  unsquashfs -f -d "$EXTRACT" "$ARCHIVE"; '
            'else '
            '  case "$URL" in '
            '  *.zip*) unzip -oq "$ARCHIVE" -d "$EXTRACT" ;; '
            '  *.tar.gz*|*.tgz*|*.tar.xz*|*.txz*|*.tar.bz2*|*.tbz2*) '
            '  tar -xf "$ARCHIVE" -C "$EXTRACT" ;; '
            '  *) echo "[BUA] Unsupported archive format: $URL"; exit 1 ;; '
            '  esac; '
            'fi; '
            'SOURCE_ROOT="$EXTRACT"; '
            'if [ -n "$SUBPATH" ]; then SOURCE_ROOT="$EXTRACT/$SUBPATH"; fi; '
            # Archives such as tailscale_1.90.6_amd64.tgz wrap everything in
            # one versioned folder: look inside it (BUA_BUNDLE_WRAPPER_DIR_V1).
            'if [ -z "$SUBPATH" ] && [ ! -e "$SOURCE_ROOT/${MEMBERS[0]}" ]; then '
            '  TOP=("$EXTRACT"/*); '
            '  if [ "${#TOP[@]}" -eq 1 ] && [ -d "${TOP[0]}" ]; then SOURCE_ROOT="${TOP[0]}"; fi; '
            'fi; '
            'test -d "$SOURCE_ROOT"; '

            # Stage every new member before touching installed payloads.
            'for MEMBER in "${MEMBERS[@]}"; do '
            '  SRC=$(find "$SOURCE_ROOT" -maxdepth 1 -type f -name "$MEMBER" -print -quit); '
            '  if [ -z "$SRC" ]; then '
            '    echo "[BUA] Missing bundle member: $MEMBER"; exit 1; '
            '  fi; '
            '  DEST="$TARGET/$MEMBER"; '
            '  NEW="${DEST}.bua-new.$$"; '
            '  rm -f "$NEW"; '
            '  cp -p "$SRC" "$NEW"; '
            + chmod_step +
            'done; '

            # Back up only payload members.
            'for MEMBER in "${MEMBERS[@]}"; do '
            '  DEST="$TARGET/$MEMBER"; '
            '  OLD="${DEST}.bua-old.$$"; '
            '  rm -f "$OLD"; '
            '  if [ -e "$DEST" ]; then mv "$DEST" "$OLD"; fi; '
            'done; '

            # Install all staged members.
            'FAILED=0; '
            'for MEMBER in "${MEMBERS[@]}"; do '
            '  DEST="$TARGET/$MEMBER"; '
            '  NEW="${DEST}.bua-new.$$"; '
            '  if ! mv "$NEW" "$DEST"; then FAILED=1; break; fi; '
            'done; '

            # Roll back the entire bundle if any member failed.
            'if [ "$FAILED" -ne 0 ]; then '
            '  for MEMBER in "${MEMBERS[@]}"; do '
            '    DEST="$TARGET/$MEMBER"; '
            '    OLD="${DEST}.bua-old.$$"; '
            '    NEW="${DEST}.bua-new.$$"; '
            '    rm -f "$DEST" "$NEW"; '
            '    if [ -e "$OLD" ]; then mv "$OLD" "$DEST"; fi; '
            '  done; '
            '  exit 1; '
            'fi; '

            # Commit.
            'for MEMBER in "${MEMBERS[@]}"; do '
            '  DEST="$TARGET/$MEMBER"; '
            '  rm -f "${DEST}.bua-old.$$"; '
            'done; '
            'trap - EXIT; '
            'rm -rf "$WORK"; '
            f"{_bua_emit_shell(q_marker)}"
        )

        return command, None

    return None, (
        "Unsupported global update recipe: "
        + recipe_type
    )


def try_adopt_verified_payload_baseline(
    app_name: str,
) -> bool:
    """
    Safely adopt the CURRENT upstream identity for an already-installed
    but previously untracked application.

    Adoption happens only when:
      1. the manifest declares an architecture-specific payload URL,
      2. the installer declares that payload's SHA-256,
      3. the downloaded archive matches that SHA-256,
      4. every regular file in the current upstream payload matches
         the corresponding installed file byte-for-byte.

    No application files are modified.
    """
    import hashlib
    import os
    import platform
    import shutil
    import tarfile
    import tempfile
    import urllib.request
    import zipfile

    entry = get_global_manifest_entry(
        app_name
    )

    if not isinstance(entry, dict):
        return False

    install_root = str(
        entry.get("install_root")
        or ""
    ).strip()

    payload_urls = (
        entry.get("payload_urls_by_arch")
        or {}
    )

    checksums = (
        entry.get("declared_payload_sha256")
        or {}
    )

    if (
        not install_root
        or not isinstance(payload_urls, dict)
        or not isinstance(checksums, dict)
    ):
        return False

    machine = platform.machine().lower()

    if machine in ("x86_64", "amd64"):
        arch = "x86_64"
    elif machine in ("aarch64", "arm64"):
        arch = "arm64"
    else:
        return False

    payload_url = str(
        payload_urls.get(arch)
        or payload_urls.get("generic")
        or ""
    ).strip()

    expected_sha256 = str(
        checksums.get(arch)
        or checksums.get("generic")
        or ""
    ).strip().lower()

    if (
        not payload_url
        or not re.fullmatch(
            r"[0-9a-f]{64}",
            expected_sha256,
        )
    ):
        return False

    # Resolve installer-style shell paths such as:
    #   $HOME/.local/example
    install_root = os.path.expanduser(
        os.path.expandvars(
            install_root
        )
    )

    installed_root = Path(
        install_root
    )

    if not installed_root.is_dir():
        return False

    work = Path(
        tempfile.mkdtemp(
            prefix="bua-baseline-verify-"
        )
    )

    payload_path = work / "payload"
    extract_root = work / "extract"

    try:
        req = urllib.request.Request(
            payload_url,
            headers={
                "User-Agent":
                    "BUA-Verified-Baseline/1",
                "Cache-Control":
                    "no-cache",
            },
        )

        digest = hashlib.sha256()

        with urllib.request.urlopen(
            req,
            timeout=60,
        ) as response, payload_path.open(
            "wb"
        ) as out:
            while True:
                chunk = response.read(
                    1024 * 1024
                )

                if not chunk:
                    break

                digest.update(chunk)
                out.write(chunk)

        actual_sha256 = digest.hexdigest()

        if actual_sha256 != expected_sha256:
            print(
                f"[BUA] Baseline verification refused for "
                f"{app_name}: payload checksum mismatch"
            )
            return False

        extract_root.mkdir(
            parents=True,
            exist_ok=True,
        )

        lower_url = payload_url.lower().split(
            "?",
            1,
        )[0]

        if lower_url.endswith(".zip"):
            with zipfile.ZipFile(
                payload_path
            ) as archive:
                archive.extractall(
                    extract_root
                )

        else:
            try:
                with tarfile.open(
                    payload_path,
                    mode="r:*",
                ) as archive:
                    # Python 3.12+ safe extraction policy.
                    try:
                        archive.extractall(
                            extract_root,
                            filter="data",
                        )
                    except TypeError:
                        archive.extractall(
                            extract_root
                        )

            except tarfile.TarError:
                return False

        # Some archives contain the payload directly at archive root.
        # Others wrap everything in one top-level directory.
        candidates = [
            extract_root,
        ]

        top_entries = list(
            extract_root.iterdir()
        )

        if (
            len(top_entries) == 1
            and top_entries[0].is_dir()
        ):
            candidates.append(
                top_entries[0]
            )

        matched_payload = False

        for payload_root in candidates:
            payload_files = [
                path
                for path in payload_root.rglob("*")
                if path.is_file()
                and not path.is_symlink()
            ]

            if not payload_files:
                continue

            candidate_matches = True

            for payload_file in payload_files:
                relative = payload_file.relative_to(
                    payload_root
                )

                installed_file = (
                    installed_root / relative
                )

                if not installed_file.is_file():
                    candidate_matches = False
                    break

                def sha256_file(path):
                    h = hashlib.sha256()

                    with path.open("rb") as fh:
                        while True:
                            block = fh.read(
                                1024 * 1024
                            )

                            if not block:
                                break

                            h.update(block)

                    return h.hexdigest()

                if (
                    sha256_file(payload_file)
                    != sha256_file(installed_file)
                ):
                    candidate_matches = False
                    break

            if candidate_matches:
                matched_payload = True
                break

        if not matched_payload:
            print(
                f"[BUA] Existing {app_name} install does not "
                f"match the current upstream payload"
            )
            return False

        snapshot = get_catalog_registration_snapshot(
            app_name,
            use_cache=False,
        )

        if not snapshot.get("supported"):
            return False

        registration = (
            snapshot.get("registration")
            or {}
        )

        app_version = str(
            registration.get("app_version")
            or ""
        ).strip()

        update_identity = str(
            registration.get("update_identity")
            or app_version
        ).strip()

        if not app_version or not update_identity:
            return False

        package_data = {
            "app_version":
                app_version,
            "update_identity":
                update_identity,
            "update_method":
                registration.get(
                    "update_method"
                )
                or "custom",
            "registration_source":
                "verified_payload_match",
            "registration_schema":
                2,
            "upstream":
                registration.get(
                    "upstream"
                )
                or {},
            "updated_at":
                datetime.now().strftime(
                    "%Y-%m-%d %H:%M:%S"
                ),
        }

        set_package_state(
            app_name,
            package_data,
        )

        print(
            f"[BUA] Verified and adopted installed "
            f"baseline for {app_name}: "
            f"{app_version}"
        )

        return True

    except Exception as exc:
        print(
            f"[BUA] Baseline verification skipped for "
            f"{app_name}: {exc}"
        )

        return False

    finally:
        shutil.rmtree(
            work,
            ignore_errors=True,
        )


def _bua_order_software_versions(left, right):
    """Order uncomplicated published numeric versions; None means incomparable.

    No assertion is made about forks, nightlies, opaque hashes or prereleases.
    Those require source-specific version ordering before enabling updates.
    """
    import re

    def parse(value):
        if not isinstance(value, str):
            return None
        match = re.fullmatch(r"[vV]?(\d+(?:\.\d+){0,5})", value.strip())
        if not match:
            return None
        numbers = tuple(int(x) for x in match.group(1).split('.'))
        return numbers + (0,) * (6 - len(numbers))

    a, b = parse(left), parse(right)
    if a is None or b is None:
        return None
    return (a > b) - (a < b)


_BUA_SCRIPT_PATH = re.compile(
    r"batocera-unofficial-addons/batocera-unofficial-addons/(?:raw/)?(?:refs/heads/)?main/([^\s\"'|;)]+?\.sh)"
)


def _bua_script_date(path: str) -> float | None:
    """Last commit time of a repo script, from SCRIPT_DATES.md (with its
    UTC offset)."""
    value = get_script_dates().get(path)
    if not value:
        return None
    try:
        return datetime.strptime(value, "%Y-%m-%d %H:%M:%S %z").timestamp()
    except ValueError:
        return github_latest_commit_date("", "", "", path)


def _bua_install_time(app_name: str) -> float | None:
    """When BUA last installed or updated this app (history or package
    state), or None if it never recorded one."""
    times = []
    stamps = [get_last_install_date(app_name)]
    entry = get_package_state(app_name) or {}
    stamps += [entry.get("updated_at"), entry.get("installed_at")]
    for stamp in stamps:
        try:
            times.append(datetime.strptime(str(stamp), "%Y-%m-%d %H:%M:%S").timestamp())
        except (TypeError, ValueError):
            pass
    return max(times) if times else None


def get_installer_change(app_name: str) -> Dict | None:
    """Has the app's BUA installer changed since it was installed?
    (BUA_INSTALLER_CHANGED_V1)

    The release check only sees the app's own version. BUA's installer
    scripts change too, e.g. to install a different launcher on
    Batocera 44, and users get that fix only by reinstalling. This is the
    commit-date check the old updater did, using SCRIPT_DATES.md: the
    installer and the BUA scripts it runs are compared with the time BUA
    last installed or updated the app. Apps BUA has no install time for
    are not flagged.
    """
    paths = []
    for text in (APPS.get(app_name, ""),):
        paths += _BUA_SCRIPT_PATH.findall(text)
    cached = str((get_global_manifest_entry(app_name) or {}).get("cached_installer") or "")
    if cached:
        try:
            paths += _BUA_SCRIPT_PATH.findall(Path(cached).read_text(encoding="utf-8", errors="replace"))
        except OSError:
            pass
    paths = [p for p in dict.fromkeys(paths) if not p.endswith("_uninstall.sh")]
    if not paths:
        return None
    installed = _bua_install_time(app_name)
    if installed is None:
        return None
    changed = [(when, path) for path in paths for when in [_bua_script_date(path)] if when]
    if not changed:
        return None
    when, path = max(changed)
    if when <= installed + 60:
        return None
    return {
        "script": path,
        "date": datetime.fromtimestamp(when, timezone.utc).strftime("%Y-%m-%d"),
    }


def get_app_version_status(app_name: str) -> Dict:
    """Release check plus installer check: an app whose BUA installer
    changed since it was installed is offered a reinstall even when its
    version is current (BUA_INSTALLER_CHANGED_V1)."""
    status = _get_release_version_status(app_name)
    try:
        change = get_installer_change(app_name)
    except Exception:
        change = None
    if not change or not isinstance(status, dict):
        return status
    status = dict(status)
    status["installer_changed"] = change
    if status.get("status") != "update_available" or status.get("needs_update") is not True:
        status["status"] = "update_available"
        status["needs_update"] = True
        status["latest_version"] = status.get("latest_version") or status.get("installed_version") or ""
    # Bind the reinstall to this exact installer revision.
    status["latest_update_identity"] = f"{status.get('latest_update_identity')}|installer@{change['date']}"
    return status


def _get_release_version_status(app_name: str) -> Dict:
    """
    Compare the installed update identity with the latest identity
    reported by the app's current BUA installer.

    app_version is human-readable.
    update_identity is the authoritative comparison key.
    """
    if app_name == SWITCH_APP_NAME:
        switch_status = get_switch_version_status(app_name)

        if switch_status is not None:
            return switch_status

    metadata = get_registered_version_metadata(
        app_name
    )

    registered_version = metadata.get(
        "app_version"
    )

    installed_identity = (
        metadata.get("update_identity")
        or registered_version
    )

    probe_version = read_version_probe(
        metadata.get("version_probe")
    )

    installed_version = (
        probe_version
        or registered_version
    )

    latest_version = None
    latest_identity = None
    snapshot_error = None

    snapshot = get_catalog_registration_snapshot(
        app_name
    )

    if snapshot.get("supported"):
        latest_registration = (
            snapshot.get("registration") or {}
        )

        latest_version = (
            latest_registration.get("app_version")
        )

        latest_identity = (
            latest_registration.get("update_identity")
            or latest_version
        )

    else:
        snapshot_error = snapshot.get("error")

    # Compare BOTH advertised sources. The independent developer is not
    # subordinate to BUA; whichever has the newer comparable release wins.
    # Ties prefer BUA for its established integration and install metadata.
    official_version = latest_version
    parent_version = get_latest_app_version(app_name)
    latest_source = "bua" if latest_version else None
    source_comparison_error = None

    if parent_version and not latest_version:
        latest_version = parent_version
        latest_identity = parent_version
        latest_source = "parent"
    elif parent_version and latest_version:
        order = _bua_order_software_versions(parent_version, latest_version)
        if order is not None and order > 0:
            latest_version = parent_version
            latest_identity = parent_version
            latest_source = "parent"
        # When the parent release and BUA's own identity cannot be
        # ordered, BUA's identity (what its installer installs today)
        # stays the latest (BUA_VERSION_FALLBACK_V1).

    registration_mismatch = bool(
        probe_version
        and registered_version
        and probe_version != registered_version
    )

    if not installed_version:
        adopted = try_adopt_verified_payload_baseline(
            app_name
        )

        if adopted:
            metadata = get_registered_version_metadata(
                app_name
            )

            registered_version = metadata.get(
                "app_version"
            )

            installed_identity = (
                metadata.get("update_identity")
                or registered_version
            )

            probe_version = read_version_probe(
                metadata.get("version_probe")
            )

            installed_version = (
                probe_version
                or registered_version
            )

        flatpak_id = _flatpak_app_id(latest_identity)
        if not installed_version and flatpak_id:
            branch = str(latest_identity).split(":")[2]
            local = _flatpak_installed_identity(flatpak_id, branch)
            if local:
                installed_version = registered_version = "rolling"
                installed_identity = local

        if not installed_version:
            # Installed before the updater (or by hand): nothing records
            # which release is on disk. When the latest release is known,
            # offer the update; installing it records the version from
            # then on (BUA_VERSION_FALLBACK_V1).
            if latest_identity and latest_source:
                return {
                    "status": "update_available",
                    "needs_update": True,
                    "untracked": True,
                    "installed_version": None,
                    "latest_version": latest_version,
                    "latest_source": latest_source,
                    "installed_update_identity": None,
                    "latest_update_identity": latest_identity,
                    "registered_version": registered_version,
                    "probe_version": probe_version,
                    "registration_mismatch": registration_mismatch,
                    "error": None,
                }
            return {
                "status": "unknown",
                "needs_update": False,
                "installed_version": None,
                "latest_version": latest_version,
                "latest_source": latest_source,
                "installed_update_identity": installed_identity,
                "latest_update_identity": latest_identity,
                "registered_version": registered_version,
                "probe_version": probe_version,
                "registration_mismatch": registration_mismatch,
                "error": snapshot_error or "Latest release could not be determined",
            }

    if not installed_identity:
        if probe_version and latest_version:
            installed_cmp = str(probe_version).strip()
            latest_cmp = str(latest_version).strip()

            if installed_cmp.lower().startswith("v"):
                installed_cmp = installed_cmp[1:]

            if latest_cmp.lower().startswith("v"):
                latest_cmp = latest_cmp[1:]

            order = _bua_order_software_versions(latest_version, installed_version)
            same = installed_cmp == latest_cmp
            differs = order is None and not same
            needs_update = (
                (order is not None and order > 0) or differs
            ) and source_comparison_error is None
            unknown = (order is None and not differs and not same) or source_comparison_error is not None

            return {
                "status": (
                    "unknown" if unknown else
                    "update_available" if needs_update else "current"
                ),
                "needs_update": needs_update,
                "installed_version": installed_version,
                "latest_version": latest_version,
                "latest_source": latest_source,
                "installed_update_identity": None,
                "latest_update_identity": latest_identity,
                "registered_version": registered_version,
                "probe_version": probe_version,
                "registration_mismatch": registration_mismatch,
                "error": (
                    source_comparison_error
                    or "Versions cannot be ordered" if unknown else None
                ),
            }

        return {
            "status": "unknown",
            "needs_update": False,
            "installed_version": installed_version,
            "latest_version": latest_version,
            "latest_source": latest_source,
            "installed_update_identity": None,
            "latest_update_identity": latest_identity,
            "registered_version": registered_version,
            "probe_version": probe_version,
            "registration_mismatch": registration_mismatch,
            "error": "Installed update identity is unknown",
        }

    if not latest_identity:
        return {
            "status": "unknown",
            "needs_update": False,
            "installed_version": installed_version,
            "latest_version": latest_version,
            "latest_source": latest_source,
            "installed_update_identity": installed_identity,
            "latest_update_identity": None,
            "registered_version": registered_version,
            "probe_version": probe_version,
            "registration_mismatch": registration_mismatch,
            "error": snapshot_error,
        }

    order = _bua_order_software_versions(latest_version, installed_version)
    if source_comparison_error:
        return {
            "status": "unknown", "needs_update": False,
            "installed_version": installed_version,
            "latest_version": latest_version,
            "latest_source": latest_source,
            "installed_update_identity": installed_identity,
            "latest_update_identity": latest_identity,
            "registered_version": registered_version,
            "probe_version": probe_version,
            "registration_mismatch": registration_mismatch,
            "error": source_comparison_error,
        }
    if order is not None:
        # A lower published version must never count as an update.
        needs_update = order > 0
        # Preserve the original BUA revision/identity mechanism for
        # software with the same public version but a new BUA payload.
        if order == 0 and latest_source == "bua":
            needs_update = installed_identity != latest_identity
    elif (
        installed_version is not None
        and latest_version is not None
        and str(installed_version).strip() == str(latest_version).strip()
    ):
        needs_update = installed_identity != latest_identity
    else:
        # Nightlies, payload dates, commit hashes: no numeric order, but
        # a different identity from the latest release is not the latest
        # release (BUA_VERSION_FALLBACK_V1).
        needs_update = installed_identity != latest_identity

    return {
        "status": (
            "update_available"
            if needs_update
            else "current"
        ),
        "needs_update": needs_update,
        "installed_version": installed_version,
        "latest_version": latest_version,
        "latest_source": latest_source,
        "installed_update_identity": installed_identity,
        "latest_update_identity": latest_identity,
        "registered_version": registered_version,
        "probe_version": probe_version,
        "registration_mismatch": registration_mismatch,
        "error": None,
    }


UPDATE_POLICIES: Dict[str, str] = {}


def get_update_method(app_name: str) -> str:
    """Return the approved BUA update method for one package."""
    return UPDATE_POLICIES.get(app_name, "unsupported")


def can_auto_update(app_name: str) -> bool:
    """Return True only when BUA currently has an approved automatic updater."""
    return get_update_method(app_name) == "reinstall"


GLOBAL_MANIFEST_PATH = Path(
    "/userdata/system/add-ons/bua/updater/catalog/global/"
    "global-update-manifest.json"
)


GLOBAL_MANIFEST_FINGERPRINT_PATH = Path(
    "/userdata/system/add-ons/bua/updater/catalog/global/"
    "catalog-apps-fingerprint.txt"
)


GLOBAL_MANIFEST_BUILDER = Path(
    "/userdata/system/add-ons/bua/updater/catalog/"
    "build_global_update_manifest.py"
)


def get_live_apps_fingerprint() -> str:
    """
    Return a stable fingerprint of the complete live BUA APPS catalog.

    Any app addition, removal, rename, or installer-command change
    changes this fingerprint.
    """
    import hashlib

    payload = json.dumps(
        sorted(
            (
                str(app),
                str(command),
            )
            for app, command in APPS.items()
        ),
        ensure_ascii=False,
        separators=(",", ":"),
    ).encode("utf-8")

    return hashlib.sha256(
        payload
    ).hexdigest()


_GLOBAL_MANIFEST_LOCK = threading.Lock()


GLOBAL_MANIFEST_LOCK_PATH = Path(
    "/userdata/system/add-ons/bua/updater/catalog/global/"
    ".manifest-rebuild.lock"
)


GLOBAL_MANIFEST_TIMEOUT = 300


def _read_manifest_fingerprint() -> str:
    try:
        return GLOBAL_MANIFEST_FINGERPRINT_PATH.read_text(encoding="utf-8").strip()
    except Exception:
        return ""


def ensure_global_manifest_current(progress=None) -> Dict:
    """
    Rebuild the canonical global update manifest only when the live
    APPS catalog has changed.

    Runs inside the updater scan thread, so network work never blocks
    the pygame UI thread. Only one rebuild runs at a time
    (BUA_SCAN_SINGLE_FLIGHT_V1): a second caller, from this process or
    another BUA instance, waits for it and then reuses its result.
    progress(done, total), when given, is called as installers finish.
    """
    result = {
        "rebuilt": False,
        "current": False,
        "error": None,
    }

    live_fingerprint = get_live_apps_fingerprint()

    def current() -> bool:
        return (
            GLOBAL_MANIFEST_PATH.is_file()
            and _read_manifest_fingerprint() == live_fingerprint
        )

    if current():
        result["current"] = True
        return result

    if not GLOBAL_MANIFEST_BUILDER.is_file():
        result["error"] = "Global manifest builder is missing"
        return result

    with _GLOBAL_MANIFEST_LOCK:
        lock_handle = None
        try:
            GLOBAL_MANIFEST_LOCK_PATH.parent.mkdir(parents=True, exist_ok=True)
            lock_handle = open(GLOBAL_MANIFEST_LOCK_PATH, "a")
            fcntl.flock(lock_handle, fcntl.LOCK_EX)
        except Exception:
            lock_handle = None  # still serialized within this process

        try:
            # Another scan may have finished the rebuild while we waited.
            if current():
                result["current"] = True
                return result

            output_tail: List[str] = []
            try:
                process = subprocess.Popen(
                    [sys.executable, str(GLOBAL_MANIFEST_BUILDER)],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    text=True,
                    bufsize=1,
                )
            except Exception as exc:
                result["error"] = f"Manifest rebuild failed: {exc}"
                return result

            timed_out = threading.Event()

            def _kill_on_timeout():
                timed_out.set()
                process.kill()

            timer = threading.Timer(GLOBAL_MANIFEST_TIMEOUT, _kill_on_timeout)
            timer.start()
            try:
                assert process.stdout is not None
                for line in process.stdout:
                    line = line.rstrip("\n")
                    output_tail = (output_tail + [line])[-20:]
                    match = re.match(r"^\[(\d+)/(\d+)\]", line)
                    if match and progress:
                        try:
                            progress(int(match.group(1)), int(match.group(2)))
                        except Exception:
                            pass
                returncode = process.wait()
            finally:
                timer.cancel()

            if returncode != 0:
                if timed_out.is_set():
                    result["error"] = (
                        f"Manifest rebuild timed out after {GLOBAL_MANIFEST_TIMEOUT}s"
                    )
                else:
                    result["error"] = f"Manifest rebuild exited {returncode}"
                    output = "\n".join(output_tail).strip()
                    if output:
                        result["error"] += ": " + output[-500:]
                return result

            if not GLOBAL_MANIFEST_PATH.is_file():
                result["error"] = (
                    "Manifest rebuild completed but no manifest was produced"
                )
                return result

            try:
                GLOBAL_MANIFEST_FINGERPRINT_PATH.write_text(
                    live_fingerprint + "\n",
                    encoding="utf-8",
                )
            except Exception as exc:
                result["error"] = (
                    f"Manifest rebuilt but fingerprint could not be saved: {exc}"
                )
                # The rebuilt manifest itself is still usable.
                result["rebuilt"] = True
                result["current"] = True
                return result

            # Registration snapshots may have been generated from the old
            # catalog. Force subsequent version checks to use the new manifest.
            REGISTRATION_SNAPSHOT_CACHE.clear()

            result["rebuilt"] = True
            result["current"] = True
            return result
        finally:
            if lock_handle is not None:
                try:
                    fcntl.flock(lock_handle, fcntl.LOCK_UN)
                    lock_handle.close()
                except Exception:
                    pass


def repair_optional_integrations():
    """Reapply optional BUA integration patches without blocking startup."""
    patchers = [
        "/userdata/system/add-ons/bua/updater/integrations/apply_switch_nextendo.py",
    ]

    for patcher in patchers:
        if not os.path.isfile(patcher):
            continue

        try:
            result = subprocess.run(
                [sys.executable, patcher],
                check=False,
                timeout=15,
                capture_output=True,
                text=True,
            )

            if result.returncode == 0:
                print(f"[BUA] Integration repair OK: {os.path.basename(patcher)}")
            else:
                print(
                    f"[BUA] Integration repair returned "
                    f"{result.returncode}: {os.path.basename(patcher)}"
                )

        except Exception as e:
            print(
                f"[BUA] Optional integration repair failed "
                f"for {os.path.basename(patcher)}: {e}"
            )


# The updater's scan runs on a shared object, not on the screen
# (BUA_SCAN_SINGLE_FLIGHT_V1). Leaving the updater does not stop it, and
# opening the updater again attaches to it instead of starting a second
# scan; a scan that finished while the updater was closed shows its
# results straight away.
_UPDATER_SCAN = None


_UPDATER_SCAN_RESULT_TTL = 600  # seconds an unseen result stays offered


class _UpdaterScanState:
    PHASE_SCAN_SELECT = "scan_select"
    PHASE_SCANNING = "scanning"
    PHASE_RESULTS = "results"

    def __init__(self, apps: List[str]):
        self.apps = list(apps)
        self.phase = self.PHASE_SCANNING
        self.loading = True
        self.error: str | None = None
        self.idx = 0
        self.items: List[Tuple[str, str, bool, str]] = [
            (app, tr("updater_waiting_to_scan", "Waiting to scan"), False, "") for app in apps
        ]
        self.selected: Dict[str, bool] = {}
        self.scan_target_count = len(apps)
        self.scan_progress = tr("updater_scan_starting", "Starting scan...")
        self.finished_at: float | None = None
        self.seen = False


class UpdaterScreen(BaseScreen):
    """
    Two-stage updater (ported from PR #166 into the console-style GUI):

      1. Choose which installed BUA apps to scan.
      2. Scan only those apps against their parent sources and show the
         update checklist.
    """

    PHASE_SCAN_SELECT = "scan_select"
    PHASE_SCANNING = "scanning"
    PHASE_RESULTS = "results"

    def __init__(self):
        global _SCRIPT_DATES_CACHE

        _SCRIPT_DATES_CACHE = None

        self.items: List[
            Tuple[str, str, bool, str]
        ] = []

        self.idx = 0
        self.selected: Dict[str, bool] = {}
        self.loading = False
        self.error: str | None = None
        self.needs_rescan = False

        self.pending_uninstall: Tuple[str, str] | None = None
        self.pending_queue: List[Tuple[str, str]] | None = None

        self.phase = self.PHASE_SCAN_SELECT
        self.scan_target_count = 0
        self.scan: _UpdaterScanState | None = None
        self.scan_progress = ""

        self._prepare_scan_selection()

        active = _UPDATER_SCAN
        if active is not None and (
            active.loading
            or (
                not active.seen
                and active.finished_at is not None
                and time.time() - active.finished_at < _UPDATER_SCAN_RESULT_TTL
            )
        ):
            self._attach_scan(active)


    def _get_installed_apps(self) -> List[str]:
        """
        Return all installed apps known to the BUA catalog/history.
        """
        json_installed = [
            k
            for k in APPS.keys()
            if is_installed(k)
        ]

        dir_installed_dict = (
            scan_installed_addons_directory()
        )

        installed_apps = list(
            set(
                json_installed
                + list(
                    dir_installed_dict.keys()
                )
            )
        )

        installed_apps = [
            app
            for app in installed_apps
            if app in APPS
        ]

        installed_apps.sort(
            key=str.lower
        )

        return installed_apps


    def _prepare_scan_selection(self):
        """
        Initial updater screen: checklist of installed BUA apps.
        Nothing is selected by default.
        """
        self.phase = self.PHASE_SCAN_SELECT
        self.loading = False
        self.error = None
        self.idx = 0
        self.scan_target_count = 0

        installed_apps = (
            self._get_installed_apps()
        )

        self.items = [
            (
                app,
                "Select to scan",
                True,
                "",
            )
            for app in installed_apps
        ]

        self.selected = {
            app: False
            for app in installed_apps
        }


    def _toggle_select_all(self):
        """
        Select all installed apps, or deselect all if all are
        currently selected.
        """
        if (
            self.phase
            != self.PHASE_SCAN_SELECT
            or self.loading
            or not self.items
        ):
            return

        apps = [
            item[0]
            for item in self.items
        ]

        all_selected = bool(apps) and all(
            self.selected.get(app, False)
            for app in apps
        )

        new_value = not all_selected

        for app in apps:
            self.selected[app] = new_value


    def _start_selected_scan(self):
        """
        Begin update checking only for apps selected on the
        first-stage checklist.
        """
        if (
            self.loading
            or self.phase
            != self.PHASE_SCAN_SELECT
        ):
            return

        selected_apps = [
            app
            for app, enabled
            in self.selected.items()
            if enabled
        ]

        if not selected_apps:
            push_screen(
                InfoDialog(
                    t("updater"),
                    [tr("updater_select_one", "Select at least one installed application to scan.")],
                )
            )
            return

        selected_apps.sort(
            key=str.lower
        )

        self.phase = self.PHASE_SCANNING
        self.loading = True
        self.error = None
        self.idx = 0
        self.scan_target_count = len(
            selected_apps
        )

        # Keep a visible list while scanning.
        self.items = [
            (
                app,
                "Waiting to scan",
                False,
                "",
            )
            for app in selected_apps
        ]

        self.selected = {}

        # A fresh scan supersedes any pending return-to-selection.
        self.needs_rescan = False

        global _UPDATER_SCAN
        scan = _UpdaterScanState(selected_apps)
        _UPDATER_SCAN = scan

        def run_scan():
            try:
                UpdaterScreen._scan_selected(scan, selected_apps, use_cache=False)
            finally:
                scan.finished_at = time.time()

        threading.Thread(target=run_scan, daemon=True).start()
        self._attach_scan(scan)


    def _scan_selected(
        self,
        installed_apps: List[str],
        use_cache: bool = False,
    ):
        """
        Scan only the apps explicitly selected by the user.
        """
        try:
            self.scan_progress = tr("updater_refreshing_catalog", "Refreshing update catalog...")

            def manifest_progress(done, total):
                self.scan_progress = tr("updater_refreshing_catalog_progress",
                                        "Refreshing update catalog ({done}/{total})", done=done, total=total)

            manifest_refresh = (
                ensure_global_manifest_current(manifest_progress)
            )

            if manifest_refresh.get("error"):
                print(
                    "[BUA] Global manifest refresh: "
                    + str(
                        manifest_refresh.get(
                            "error"
                        )
                    )
                )

            elif manifest_refresh.get(
                "rebuilt"
            ):
                print(
                    "[BUA] Global update manifest "
                    "rebuilt for current APPS catalog"
                )

            results = []
            # Apps offered an update only because no installed version is
            # recorded: shown, but not ticked by default.
            untracked_apps = set()

            for app_number, app in enumerate(installed_apps, 1):
                self.scan_progress = tr("updater_checking_app", "Checking {app} ({number}/{total})",
                                        app=app, number=app_number, total=len(installed_apps))
                if (
                    use_cache
                    and app in GITHUB_CACHE
                ):
                    (
                        status,
                        needs,
                        detail,
                    ) = GITHUB_CACHE[app]

                    results.append(
                        (
                            app,
                            status,
                            needs,
                            detail,
                        )
                    )
                    continue

                blocked = (
                    get_blocked_source_status(
                        app
                    )
                )

                if blocked:
                    status = tr("updater_blocked_source", "Blocked source")
                    needs = False

                    detail = (
                        blocked.get("reason")
                        or blocked.get("source")
                        or
                        tr("updater_source_unavailable", "Required source is unavailable")
                    )

                    GITHUB_CACHE[app] = (
                        status,
                        needs,
                        detail,
                    )

                    results.append(
                        (
                            app,
                            status,
                            needs,
                            detail,
                        )
                    )
                    continue

                app_status = (
                    get_app_version_status(app)
                )
                BUA_SCANNED_RELEASES[app] = _bua_release_fingerprint(app_status)

                app_state = (
                    app_status.get("status")
                )

                installed_version = (
                    app_status.get(
                        "installed_version"
                    )
                    or ""
                )

                latest_version = (
                    app_status.get(
                        "latest_version"
                    )
                    or ""
                )

                details = []

                if (
                    app_state
                    == "update_available"
                ):
                    (
                        update_cmd,
                        update_error,
                    ) = (
                        build_parent_update_command(
                            app, app_status
                        )
                    )

                    reinstall = bool(update_cmd) and UPDATE_METHODS.get(app) == "reinstall"
                    script_change = app_status.get("installer_changed")
                    if update_cmd and script_change:
                        status = tr("updater_script_updated", "BUA script updated")
                        needs = True
                        if get_reinstall_safety(app).get("verdict") != "keeps_settings":
                            untracked_apps.add(app)  # may reset settings: not pre-ticked
                        details.append(tr("updater_script_date", "Script {date}", date=script_change["date"]))
                    elif update_cmd and app_status.get("untracked"):
                        status = tr("updater_untracked", "Version not tracked")
                        needs = True
                        untracked_apps.add(app)
                    elif reinstall:
                        status = tr("updater_update_reinstall", "Update by reinstalling")
                        needs = True
                        untracked_apps.add(app)  # may reset settings: not pre-ticked
                    elif update_cmd:
                        status = t(
                            "update_available"
                        )
                        needs = True
                    else:
                        status = tr("updater_recipe_unavailable", "Update recipe unavailable")
                        needs = False

                    if (
                        installed_version
                        and latest_version
                        and installed_version != latest_version
                    ):
                        details.append(
                            f"{installed_version} "
                            f"-> {latest_version}"
                        )

                    elif latest_version:
                        details.append(
                            tr("updater_latest_version", "Latest {version}", version=latest_version)
                        )

                    if update_error:
                        details.append(
                            update_error
                        )

                    if reinstall and app_status.get("untracked"):
                        details.append(tr("updater_method_reinstall", "updates by reinstalling"))

                    if app_status.get("component_summary"):
                        details.append(
                            app_status["component_summary"]
                        )

                    detail = " | ".join(
                        details
                    )

                elif app_state == "current":
                    status = t(
                        "up_to_date"
                    )
                    needs = False

                    if installed_version:
                        details.append(
                            tr("updater_version", "Version {version}", version=installed_version)
                        )

                    if app_status.get("component_summary"):
                        details.append(
                            app_status["component_summary"]
                        )

                    detail = " | ".join(
                        details
                    )

                else:
                    status = tr("updater_version_unknown", "App version unknown")
                    needs = False

                    if installed_version:
                        details.append(
                            tr("updater_installed_version", "Installed {version}", version=installed_version)
                        )

                    if latest_version:
                        details.append(
                            tr("updater_latest_version", "Latest {version}", version=latest_version)
                        )

                    app_error = (
                        app_status.get(
                            "error"
                        )
                    )

                    if app_error:
                        details.append(
                            app_error
                        )

                    detail = " | ".join(
                        details
                    )

                GITHUB_CACHE[app] = (
                    status,
                    needs,
                    detail,
                )

                results.append(
                    (
                        app,
                        status,
                        needs,
                        detail,
                    )
                )

            # Updates first, then alphabetical.
            results.sort(
                key=lambda x: (
                    not x[2],
                    x[0].lower(),
                )
            )

            self.items = results

            # Preserve current updater behavior:
            # available updates begin selected.
            self.selected = {
                app: needs
                for (
                    app,
                    _status,
                    needs,
                    _detail,
                ) in self.items
                if needs and app not in untracked_apps
            }

            self.idx = 0
            self.phase = self.PHASE_RESULTS

        except Exception as e:
            self.error = str(e)
            self.phase = self.PHASE_RESULTS

        finally:
            self.loading = False


    def rescan(self, use_cache=True):
        """
        Return to the app-selection checklist after an uninstall or
        when a fresh scan selection is requested.
        """
        self._prepare_scan_selection()


    def queue_updates(self):
        if (
            self.loading
            or self.phase
            != self.PHASE_RESULTS
        ):
            return

        selected_apps = [
            app
            for app in self.selected
            if self.selected.get(
                app,
                False,
            )
        ]

        if not selected_apps:
            push_screen(
                InfoDialog(
                    t("updater"),
                    [
                        t(
                            "nothing_selected_update"
                        )
                    ],
                )
            )
            return

        unavailable = []
        queued = []

        for app in selected_apps:
            current_status = get_app_version_status(app)
            scanned = BUA_SCANNED_RELEASES.get(app)
            if scanned is None or scanned != _bua_release_fingerprint(current_status):
                unavailable.append(f"{app}: release changed; rescan before updating")
                continue
            cmd, error = (
                build_parent_update_command(
                    app, current_status
                )
            )

            if not cmd:
                unavailable.append(
                    f"{app}: "
                    f"{error or 'No update recipe'}"
                )
                continue

            queued.append((app, cmd))

        reinstalls = [app for app, _cmd in queued if UPDATE_METHODS.get(app) == "reinstall"]

        # Never drop a ticked app silently (BUA_QUEUE_REPORT_V1): say which
        # could not be queued and why, then offer to go on with the rest.
        # Warn only about the apps whose installer deletes their settings,
        # or that could not be checked (BUA_REINSTALL_SAFETY_V1).
        verdicts = {app: get_reinstall_safety(app).get("verdict") for app in reinstalls}
        resets = [app for app in reinstalls if verdicts[app] == "may_reset"]
        unchecked = [app for app in reinstalls if verdicts[app] == "unknown"]

        def _names(apps, limit=6):
            return ", ".join(apps[:limit]) + (f" (+{len(apps) - limit})" if len(apps) > limit else "")

        if resets or unchecked:
            message = []
            if resets:
                message += [
                    tr("updater_reinstall_resets",
                       "Reinstalling these deletes their add-on folder, so their settings will be reset:"),
                    _names(resets),
                ]
            if unchecked:
                message += [
                    tr("updater_reinstall_unchecked",
                       "Could not check whether these keep their settings:"),
                    _names(unchecked),
                ]
            if unavailable:
                message += [tr("updater_not_queued", "These could not be queued:")] + unavailable[:3]

            def on_confirm():
                self.pending_queue = queued

            def on_cancel():
                pass

            push_screen(ConfirmDialog(t("updater"), message, on_confirm, on_cancel))
            return

        if unavailable and queued:
            message = [tr("updater_not_queued", "These could not be queued:")] + unavailable[:6] + [
                tr("updater_queue_rest", "Queue the other updates?")
            ]

            def on_confirm_rest():
                self.pending_queue = queued

            push_screen(ConfirmDialog(t("updater"), message, on_confirm_rest, lambda: None))
            return

        self._enqueue(queued, unavailable)

    def _enqueue(self, queued, unavailable=()):
        for item in queued:
            if item not in INSTALL_QUEUE:
                INSTALL_QUEUE.append(item)

        if not INSTALL_QUEUE:
            push_screen(
                InfoDialog(
                    t("updater"),
                    unavailable
                    or [
                        "No selected applications "
                        "have a parent-source "
                        "update recipe."
                    ],
                )
            )
            return

        pop_screen()
        push_screen(
            QueueScreen()
        )

    # ------------------------------------------------------------
    # Shared scan
    # ------------------------------------------------------------

    def _attach_scan(self, scan: "_UpdaterScanState"):
        self.scan = scan
        self._sync_scan()

    def _sync_scan(self):
        """Mirror the shared scan; take its results once it finishes."""
        scan = self.scan
        if scan is None:
            return
        self.scan_target_count = scan.scan_target_count
        self.scan_progress = scan.scan_progress
        if scan.loading:
            self.phase = self.PHASE_SCANNING
            self.loading = True
            self.error = None
            self.items = list(scan.items)
            self.selected = {}
            self.idx = 0
            return
        self.phase = scan.phase
        self.loading = False
        self.error = scan.error
        self.items = list(scan.items)
        self.selected = dict(scan.selected)
        self.idx = 0
        scan.seen = True
        self.scan = None

    # ------------------------------------------------------------
    # Input
    # ------------------------------------------------------------

    def _move(self, step):
        if not self.loading and self.items:
            self.idx = max(0, min(self.idx + step, len(self.items) - 1))

    def _toggle_current(self):
        if self.loading or not self.items:
            return
        app, _status, needs, _detail = self.items[self.idx]
        # Any app can be chosen for scanning; after the scan only apps
        # with an update can be ticked.
        if self.phase == self.PHASE_SCAN_SELECT or needs:
            self.selected[app] = not self.selected.get(app, False)

    def _start(self):
        if self.loading:
            return
        if self.phase == self.PHASE_SCAN_SELECT:
            self._start_selected_scan()
        elif self.phase == self.PHASE_RESULTS:
            self.queue_updates()

    def handle(self, events):
        # Process analog stick for navigation (arcade cabinet support)
        analog_v, _analog_h = process_analog_navigation(events)
        if analog_v:
            self._move(analog_v)

        for e in events:
            if e.type == pygame.QUIT:
                clean_exit(0)
            if e.type == pygame.KEYDOWN:
                if e.key == pygame.K_ESCAPE:
                    pop_screen(); return
                if e.key == pygame.K_DOWN:
                    self._move(1)
                if e.key == pygame.K_UP:
                    self._move(-1)
                if e.key in (pygame.K_RETURN, pygame.K_KP_ENTER):
                    self._toggle_current()
                if e.key == pygame.K_x:  # Select all / deselect all
                    self._toggle_select_all()
                if e.key == pygame.K_SPACE:  # Start on keyboard
                    self._start()
            if e.type == pygame.JOYHATMOTION:
                _x, y = e.value
                if y == -1:
                    self._move(1)
                elif y == 1:
                    self._move(-1)
            if e.type == pygame.JOYBUTTONDOWN:
                if e.button in (BTN_B, BTN_BACK):  # B/Back
                    pop_screen(); return
                if e.button == BTN_A:
                    self._toggle_current()
                if e.button == BTN_X:  # Select all / deselect all
                    self._toggle_select_all()
                if e.button == BTN_START:
                    self._start()
                if e.button == BTN_Y:  # Y -> uninstall current app
                    self.uninstall_app()
                if e.button in (BTN_LB, BTN_RB):  # LB+RB -> uninstall, ignoring warnings
                    other = BTN_RB if e.button == BTN_LB else BTN_LB
                    try:
                        held = pygame.joystick.Joystick(e.joy).get_button(other)
                    except Exception:
                        held = False
                    if held:
                        self.uninstall_app(ignore_warnings=True)

    # ------------------------------------------------------------
    # Uninstall (asks first)
    # ------------------------------------------------------------

    def uninstall_app(self, ignore_warnings: bool = False):
        """Ask, then uninstall the highlighted app. With ignore_warnings the
        uninstaller gets --ignore-warning and removes it without asking."""
        if self.loading or not self.items:
            return
        app = self.items[self.idx][0]
        if not APPS.get(app):
            return

        # The uninstall command comes from the app list
        uninstall_cmd = UNINSTALL.get(app)
        if not uninstall_cmd:
            push_screen(InfoDialog(t("uninstall"), [t("uninstall_error")]))
            return
        # Only the repo's own uninstallers (curl ... | bash) get the option;
        # ones that don't support it ignore their arguments
        if ignore_warnings and uninstall_cmd.rstrip().endswith("| bash"):
            uninstall_cmd = f"{uninstall_cmd} -s -- --ignore-warning"

        message = [tr("uninstall_confirm", "Uninstall {app}?", app=app)]
        if ignore_warnings:
            message.append(tr("uninstall_confirm_skip_warnings", "Its warnings will be skipped."))

        def on_confirm():
            # ConfirmDialog closes the top screen after this callback, so
            # the uninstall screen is opened from update() on the next frame.
            self.pending_uninstall = (app, uninstall_cmd)

        def on_cancel():
            pass

        push_screen(ConfirmDialog(f"{t('uninstall')}: {app}", message, on_confirm, on_cancel))

    def update(self):
        if self.scan is not None:
            self._sync_scan()
        if self.pending_queue:
            queued, self.pending_queue = self.pending_queue, None
            # ConfirmDialog has closed; now leave for the queue screen.
            self._enqueue(queued)
            return
        if self.pending_uninstall:
            app, uninstall_cmd = self.pending_uninstall
            self.pending_uninstall = None
            # Run it like an install, so questions the uninstaller asks with
            # dialog are shown in the app. RunListScreen removes the app from
            # history and package state when an "(Uninstall)" job succeeds.
            self.needs_rescan = True
            push_screen(RunListScreen([(f"{app} (Uninstall)", uninstall_cmd)], title=f"{t('uninstall')}: {app}"))
            return
        # Back from an uninstall: return to the app-selection list so the
        # removed app disappears.
        if self.needs_rescan and not self.loading:
            self.needs_rescan = False
            self.rescan()

    # ------------------------------------------------------------
    # Drawing
    # ------------------------------------------------------------

    def draw(self):
        draw_background(screen)
        f = UI_FONTS
        margin = S(48)

        selected_count = sum(1 for value in self.selected.values() if value)
        if self.phase == self.PHASE_SCAN_SELECT:
            subtitle = tr("updater_choose_scan", "Choose installed apps to scan ({selected}/{total} selected)",
                          selected=selected_count, total=len(self.items))
        elif self.phase == self.PHASE_RESULTS and not self.loading and self.items:
            updates = sum(1 for item in self.items if item[2])
            subtitle = tr("updater_results_summary", "{updates} update(s) available, {selected} selected",
                          updates=updates, selected=selected_count)
        else:
            subtitle = ""
        top = draw_screen_header(t("updater_title"), subtitle)

        hint_parts = []
        if not self.loading:
            if self.phase == self.PHASE_SCAN_SELECT:
                all_selected = bool(self.items) and selected_count == len(self.items)
                hint_parts.append(f"A={t('hint_toggle')}")
                hint_parts.append("X=" + (tr("hint_deselect_all", "Deselect All") if all_selected
                                          else tr("hint_select_all", "Select All")))
                hint_parts.append("Start=" + tr("hint_scan_selected", "Scan Selected"))
            elif self.phase == self.PHASE_RESULTS:
                try:
                    if self.items and self.items[self.idx][2]:
                        hint_parts.append(f"A={t('hint_toggle')}")
                except Exception:
                    pass
                hint_parts.append("Start=" + tr("hint_update_selected", "Update Selected"))
            if self.items:
                hint_parts.append(f"Y={t('hint_uninstall')}")
                hint_parts.append(f"LB+RB={t('hint_uninstall_ignore')}")
        hint_parts.append(f"B={t('hint_return')}")
        draw_footer(screen, " | ".join(hint_parts))

        if self.loading:
            if self.phase == self.PHASE_SCANNING:
                text = self.scan_progress or tr("updater_scanning_selected", "Scanning selected applications ({count})...",
                                                count=self.scan_target_count)
            else:
                text = t("scanning_updates")
            draw_spinner(screen, (margin + S(14), top + S(14)), S(14), ACCENT)
            draw_text(screen, text, f["body"], MUTED, (margin + S(40), top + S(14) - f["body"].get_height() // 2))
            return
        if self.error:
            draw_text(screen, f"{t('error')}: {self.error}", f["body"], (232, 92, 92), (margin, top))
            return
        if not self.items:
            draw_text(screen, t("no_installed"), f["body"], MUTED, (margin, top))
            return

        pitch, row_h = S(70), S(60)
        first, rows = list_window(len(self.items), self.idx, top, pitch)
        for i in range(first, min(len(self.items), first + rows)):
            app, status, needs, detail = self.items[i]
            rect = pygame.Rect(margin, top + (i - first) * pitch, W - 2 * margin, row_h)
            if self.phase == self.PHASE_SCAN_SELECT:
                # Before the scan: the app's description, ticked when chosen
                draw_app_row(rect, app, i == self.idx, checked=self.selected.get(app, False))
            else:
                suffix = f" - {detail}" if detail else ""
                draw_app_row(rect, app, i == self.idx, checked=needs and self.selected.get(app, False),
                             subtitle=status + suffix, subtitle_color=ACCENT if needs else MUTED)


# ------------------------------
# Package translations and hooks
# ------------------------------

_UPDATER_PACKAGE_DIR = "/userdata/system/add-ons/bua/updater"
_UPDATER_TRANSLATIONS = {}


def _updater_translation(key: str):
    """Updater strings ship with the package, so they never depend on
    which translation keys the main repo has."""
    for lang in (CURRENT_LANGUAGE, "en"):
        if lang not in _UPDATER_TRANSLATIONS:
            try:
                with open(f"{_UPDATER_PACKAGE_DIR}/translation/{lang}.json", encoding="utf-8") as fh:
                    _UPDATER_TRANSLATIONS[lang] = json.load(fh)
            except Exception:
                _UPDATER_TRANSLATIONS[lang] = {}
        value = _UPDATER_TRANSLATIONS[lang].get(key)
        if value:
            return value
    return None


def tr(key: str, default: str, **fields) -> str:
    """Updater text: the package's translation, then BUA's, then the
    English default. Fills {placeholders} from fields."""
    value = _updater_translation(key)
    if not value:
        value = t(key)
        if not value or value == key:
            value = default
    if not fields:
        return value
    try:
        return value.format(**fields)
    except Exception:
        return default.format(**fields)


_REGISTRATION_FILES = {}


def _hook_wrap_install(name: str, cmd: str):
    """Before an install job: give the installer bua_register, and use a
    registration-aware adapter where one is mapped. Registration lines
    go to a file instead of the job's output."""
    if "(Uninstall)" in name:
        return cmd, ""
    path = f"/tmp/bua-register-{os.getpid()}-{abs(hash(name))}.txt"
    try:
        os.unlink(path)
    except OSError:
        pass
    _REGISTRATION_FILES[name] = path
    dev_adapter = get_dev_registration_adapter(name)
    if dev_adapter and "BUA_PARENT_UPDATE=1;" not in cmd:
        cmd = "source " + repr(dev_adapter)
    return cmd, f"export BUA_REGISTRATION_FILE={shlex.quote(path)}\n" + get_bua_registration_shell_helper()


def _hook_job_finished(job_name: str, success: bool):
    """After a job: forget uninstalled apps; record exactly what a
    successful install put on disk."""
    if "(Uninstall)" in job_name:
        if success:
            remove_package_state(job_name.replace(" (Uninstall)", ""))
        return
    path = _REGISTRATION_FILES.pop(job_name, None)
    lines = []
    if path:
        try:
            with open(path, encoding="utf-8", errors="replace") as fh:
                lines = fh.read().splitlines()
            os.unlink(path)
        except OSError:
            pass
    if not success or job_name not in APPS:
        return
    if apply_install_registration(job_name, lines):
        return
    snapshot = get_catalog_registration_snapshot(job_name)
    registration = (snapshot.get("registration") or {}) if snapshot.get("supported") else {}
    registered = False
    if registration:
        marker = BUA_REGISTRATION_PREFIX + json.dumps(registration, sort_keys=True, separators=(",", ":"))
        source_label = (
            "generic_catalog"
            if str(snapshot.get("source") or "").startswith(("http://", "https://"))
            else "registration_adapter"
        )
        registered = apply_install_registration(job_name, [marker], registration_source=source_label)
    if not registered:
        print(f"[BUA] Unable to determine installed application identity for {job_name}")


BUA_HOOKS["wrap_install"].append(_hook_wrap_install)
BUA_HOOKS["job_finished"].append(_hook_job_finished)
BUA_HOOKS["startup"].append(repair_optional_integrations)


def _bua_emit_shell(quoted_marker: str) -> str:
    """Shell that records a registration line: into the job's
    BUA_REGISTRATION_FILE when BUA set one, else on stdout."""
    return (
        '{ if [ -n "${BUA_REGISTRATION_FILE:-}" ]; then printf "%s\n" ' + quoted_marker
        + ' >> "$BUA_REGISTRATION_FILE"; else printf "%s\n" ' + quoted_marker + '; fi; }'
    )
