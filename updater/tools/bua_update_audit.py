#!/usr/bin/env python3
"""
BUA updater audit: a mock update for every app in the catalog.

For each app it runs the updater's real code paths, without installing
anything:

  latest   - can the updater find the latest release? (catalog snapshot,
             parent release)
  real     - what the scan shows today for apps installed on this box
  mock     - pretend an older release is installed: does the scan offer
             an update, and can it build the update command?

Nothing is installed or downloaded into place. Package state is read
from a temporary copy, so /userdata/system/add-ons/bua_packages.json is
never changed.

Usage:  python3 bua_update_audit.py [--only APP] [--frontend PATH]
Writes: /userdata/system/add-ons/bua/update-audit.json and .txt
"""

import argparse
import json
import os
import shutil
import sys
import tempfile
import time
import traceback

FRONTEND_URL = "https://github.com/batocera-unofficial-addons/batocera-unofficial-addons/raw/refs/heads/main/app/bua_installerx86.py"
PACKAGE = "/userdata/system/add-ons/bua/updater/bua_updater_overlay.py"
REAL_STATE = "/userdata/system/add-ons/bua_packages.json"
OUT_DIR = "/userdata/system/add-ons/bua"

parser = argparse.ArgumentParser()
parser.add_argument("--only", action="append", default=[], help="audit only this app (repeatable)")
parser.add_argument("--frontend", help="BUA frontend to load (default: download main's, as BUA.sh does)")
parser.add_argument("--package", default=PACKAGE, help="updater package overlay to load into it")
parser.add_argument("--apps-json", help="read the app list from this file instead of the repo")
parser.add_argument("--real-pygame", action="store_true", help="load BUA with the real pygame")
args = parser.parse_args()

# Work on a copy of the package state; never the real file.
work = tempfile.mkdtemp(prefix="bua-audit-")
state_copy = os.path.join(work, "bua_packages.json")
if os.path.isfile(REAL_STATE):
    shutil.copy2(REAL_STATE, state_copy)
os.environ["BUA_PACKAGE_STATE_FILE"] = state_copy

parser_real = "--real-pygame" in sys.argv

# Headless: the audit draws nothing, and Batocera's pygame has no
# "dummy" video driver, so BUA is loaded with a stand-in pygame that
# never touches the display. --real-pygame uses the real one.
if not parser_real:
    import types
    from unittest import mock

    _pg = mock.MagicMock(name="pygame")
    _pg.joystick.get_count.return_value = 0
    _pg.display.Info.return_value.current_w = 1280
    _pg.display.Info.return_value.current_h = 720
    _pg.display.set_mode.return_value.get_size.return_value = (1280, 720)

    class _StandInPygame(types.ModuleType):
        def __getattr__(self, name):
            return getattr(_pg, name)

    _module = _StandInPygame("pygame")
    sys.modules["pygame"] = _module
    for _sub in ("display", "font", "mixer", "joystick", "event", "time", "mouse", "draw", "image", "freetype", "gfxdraw", "transform"):
        sys.modules["pygame." + _sub] = getattr(_pg, _sub)
os.environ.pop("DISPLAY", None)

import importlib.util  # noqa: E402

if not args.frontend:
    import urllib.request
    args.frontend = os.path.join(tempfile.mkdtemp(prefix="bua-audit-"), "bua_installerx86.py")
    print("[audit] downloading", FRONTEND_URL, flush=True)
    with urllib.request.urlopen(FRONTEND_URL, timeout=60) as resp, open(args.frontend, "wb") as out:
        out.write(resp.read())
print("[audit] loading", args.frontend, flush=True)
spec = importlib.util.spec_from_file_location("bua_frontend", args.frontend)
bua = importlib.util.module_from_spec(spec)
sys.modules["bua_frontend"] = bua
spec.loader.exec_module(bua)
# Load the updater package the way BUA does, without its startup repairs.
_run_hooks = bua.run_hooks
bua.run_hooks = lambda *a, **k: None
if not bua.load_updater_package(args.package):
    sys.exit(f"[audit] updater package not loaded: {args.package}")
bua.run_hooks = _run_hooks
assert bua.PACKAGE_STATE_FILE == state_copy, "package state not redirected"

if args.apps_json:
    with open(args.apps_json, encoding="utf-8") as f:
        tables = bua.build_app_tables(json.load(f))
    bua.APPS, bua.DESCRIPTIONS, bua.CATEGORIES, bua.UNINSTALL = tables

apps = sorted(bua.APPS, key=str.lower)
if args.only:
    apps = [a for a in apps if a in set(args.only)]
print(f"[audit] {len(apps)} apps", flush=True)

print("[audit] refreshing update catalog...", flush=True)
manifest = bua.ensure_global_manifest_current()
if manifest.get("error"):
    print("[audit] catalog refresh:", manifest["error"], flush=True)


def installed(app):
    try:
        return bool(bua.is_installed(app)) or app in bua.scan_installed_addons_directory()
    except Exception:
        return False


def mock_previous(version):
    """A plausible older version string in the same format."""
    v = str(version or "")
    if v.startswith("payload@"):
        return "payload@2000-01-01"
    if v.startswith("sha256@"):
        return "sha256@000000000000"
    if v.startswith("installer@"):
        return "installer@2000-01-01"
    stripped = v.lstrip("vV")
    if stripped and all(p.isdigit() for p in stripped.split(".")):
        return ("v" if v[:1] in "vV" else "") + "0.0.1"
    return "mock-previous"


def classify(status, cmd_error=None, method=None):
    if status.get("status") == "update_available":
        if cmd_error:
            return "NO_UPDATE_COMMAND"
        return "OK_" + (method or "payload").upper()
    if status.get("status") == "current":
        return "SAYS_CURRENT"
    err = str(status.get("error") or "")
    if "Download link is broken" in err:
        return "BROKEN_DOWNLOAD"
    if "rate limit" in err.lower():
        return "GITHUB_RATE_LIMIT"
    if "Installed application version is unknown" in err:
        return "UNKNOWN_NO_INSTALLED_VERSION"
    if "not safely orderable" in err or "cannot be ordered" in err.lower():
        return "UNKNOWN_UNORDERABLE"
    if not status.get("latest_update_identity"):
        return "UNKNOWN_NO_LATEST"
    return "UNKNOWN_OTHER"


report = []
t_all = time.time()
for number, app in enumerate(apps, 1):
    t0 = time.time()
    row = {"app": app, "installed_here": installed(app)}
    try:
        entry = bua.get_global_manifest_entry(app) or {}
        row["source_family"] = entry.get("source_family")
        row["conversion_status"] = entry.get("conversion_status")
        row["github"] = "/".join(x for x in (entry.get("github_owner"), entry.get("github_repo")) if x) or None
        row["adapter"] = bool(bua.get_dev_registration_adapter(app))

        snap = bua.get_catalog_registration_snapshot(app, use_cache=False)
        reg = snap.get("registration") or {}
        row["latest"] = {
            "supported": bool(snap.get("supported")),
            "version": reg.get("app_version"),
            "identity": reg.get("update_identity"),
            "upstream": reg.get("upstream"),
            "source": snap.get("source"),
            "error": snap.get("error"),
        }

        # What the scan shows today (installed apps only).
        if row["installed_here"]:
            real = bua.get_app_version_status(app)
            row["real"] = {k: real.get(k) for k in ("status", "installed_version", "latest_version", "latest_source", "error")}
            real_method = None
            if real.get("status") == "update_available":
                _cmd, _err = bua.build_parent_update_command(app, real)
                real_method = getattr(bua, "UPDATE_METHODS", {}).get(app)
                row["real"]["update_command_error"] = None if _cmd else _err
            row["real"]["class"] = classify(real, row["real"].get("update_command_error"), real_method)

        # Mock: an older release is recorded as installed.
        saved = bua.get_package_state(app)
        if snap.get("supported") and reg:
            fake = dict(reg)
            fake["app_version"] = mock_previous(reg.get("app_version"))
            fake["update_identity"] = "mock:previous-release"
            fake["registration_source"] = "audit_mock"
            bua.set_package_state(app, fake)
            bua.REGISTRATION_SNAPSHOT_CACHE.pop(app, None)
            mock = bua.get_app_version_status(app)
            cmd, cmd_error = (None, None)
            if mock.get("status") == "update_available":
                cmd, cmd_error = bua.build_parent_update_command(app, mock)
            row["mock"] = {
                "status": mock.get("status"),
                "installed_version": mock.get("installed_version"),
                "latest_version": mock.get("latest_version"),
                "error": mock.get("error"),
                "update_command": bool(cmd),
                "update_command_error": cmd_error,
                "method": getattr(bua, "UPDATE_METHODS", {}).get(app),
                "class": classify(mock, cmd_error if not cmd else None, getattr(bua, "UPDATE_METHODS", {}).get(app)),
            }
            if row["mock"]["method"] == "reinstall" and hasattr(bua, "get_reinstall_safety"):
                # BUA_REINSTALL_SAFETY_V1: does re-running the installer keep settings?
                safety = bua.get_reinstall_safety(app)
                row["mock"]["reinstall_safety"] = safety.get("verdict")
                row["mock"]["reinstall_deletes"] = safety.get("paths", [])
            if app == getattr(bua, "SWITCH_APP_NAME", "Switch") and mock.get("status") == "current":
                # Switch is checked emulator by emulator from the files on
                # disk, so a recorded older release does not apply.
                row["mock"]["class"] = "OK_SWITCH_FILES"
        else:
            error = snap.get("error") or ""
        row["mock"] = {
            "class": "BROKEN_DOWNLOAD" if "Download link is broken" in error
            else "GITHUB_RATE_LIMIT" if "rate limit" in error.lower()
            else "UNKNOWN_NO_LATEST",
            "error": error,
        }
        # Leave the temporary state as it was for the next app.
        if saved:
            bua.set_package_state(app, saved)
        else:
            bua.remove_package_state(app)
    except Exception as exc:
        row["crash"] = f"{type(exc).__name__}: {exc}"
        row["trace"] = traceback.format_exc()[-1500:]
        row.setdefault("mock", {})["class"] = "CRASH"
    row["seconds"] = round(time.time() - t0, 1)
    report.append(row)
    real = row.get("real", {}).get("class", "-")
    print(f"[{number:03d}/{len(apps):03d}] {app:32.32s} mock={row['mock']['class']:28s} real={real:28s} {row['seconds']}s", flush=True)

# ---------------- summary ----------------
from collections import Counter, defaultdict  # noqa: E402

lines = [f"BUA updater audit  {time.strftime('%Y-%m-%d %H:%M')}  ({len(report)} apps, {round(time.time() - t_all)}s)", ""]
for label, key in (("MOCK UPDATE (older release recorded)", "mock"), ("REAL SCAN (apps installed on this box)", "real")):
    rows = [r for r in report if key in r]
    counts = Counter(r[key]["class"] for r in rows)
    lines.append(f"== {label}: {len(rows)} apps")
    for cls, n in counts.most_common():
        lines.append(f"  {cls:30s} {n}")
    lines.append("")
lines.append("== FAILURES (mock update), grouped by reason")
groups = defaultdict(list)
for r in report:
    m = r["mock"]
    if not m["class"].startswith("OK"):
        reason = r.get("crash") or m.get("update_command_error") or m.get("error") or (r.get("latest") or {}).get("error") or m["class"]
        groups[(m["class"], str(reason)[:110])].append(r["app"])
for (cls, reason), names in sorted(groups.items(), key=lambda kv: -len(kv[1])):
    lines.append(f"- {cls} x{len(names)}: {reason}")
    lines.append("    " + ", ".join(names))
lines.append("")
lines.append("== UPDATE BY REINSTALLING: settings (BUA_REINSTALL_SAFETY_V1)")
safety = defaultdict(list)
for r in report:
    if r["mock"].get("reinstall_safety"):
        safety[r["mock"]["reinstall_safety"]].append(r)
for verdict in ("keeps_settings", "may_reset", "unknown"):
    lines.append(f"  {verdict:30s} {len(safety[verdict])}")
for r in safety["may_reset"] + safety["unknown"]:
    lines.append(f"- {r['app']}: {r['mock']['reinstall_safety']} | deletes {', '.join(r['mock'].get('reinstall_deletes') or []) or '?'}")
lines.append("")
lines.append("== REAL SCAN not OK (installed here)")
for r in report:
    if "real" in r and not (r["real"]["class"].startswith("OK") or r["real"]["class"] == "SAYS_CURRENT"):
        lines.append(f"- {r['app']}: {r['real']['class']} | {r['real'].get('error')}")

os.makedirs(OUT_DIR, exist_ok=True)
with open(os.path.join(OUT_DIR, "update-audit.json"), "w") as f:
    json.dump(report, f, indent=1, sort_keys=True)
with open(os.path.join(OUT_DIR, "update-audit.txt"), "w") as f:
    f.write("\n".join(lines) + "\n")
# The check: every app must have a latest release and a way to update.
problems = [r["app"] for r in report if not r["mock"]["class"].startswith("OK") and r["mock"]["class"] != "BROKEN_DOWNLOAD"]
broken = [r["app"] for r in report if r["mock"]["class"] == "BROKEN_DOWNLOAD"]
lines.append("")
lines.append(f"== VERDICT: {len(report) - len(problems) - len(broken)}/{len(report)} apps can be updated; "
             f"{len(broken)} have a broken download link; {len(problems)} cannot be updated")
if problems:
    lines.append("   cannot be updated: " + ", ".join(problems))
if broken:
    lines.append("   broken download (fix the installer): " + ", ".join(broken))
print("\n".join(lines))
print(f"\n[audit] full report: {OUT_DIR}/update-audit.json and update-audit.txt")
shutil.rmtree(work, ignore_errors=True)
sys.exit(1 if problems else 0)
