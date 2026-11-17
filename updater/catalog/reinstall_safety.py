"""Does re-running a BUA installer keep the app's settings?
(BUA_REINSTALL_SAFETY_V1)

Apps with no payload recipe update by running their BUA installer again.
Most installers only overwrite program files, but a few start with
``rm -rf`` on the whole add-on folder or a config folder, which wipes
settings and saves kept there.

``analyze(script)`` reads an installer and returns::

    {"verdict": "keeps_settings" | "may_reset" | "unknown",
     "paths": [deleted folders that hold settings],
     "nested": [other installer scripts it runs]}

It runs when the global manifest is built, so any app added to BUA later
is checked the same way with no per-app list to maintain. The updater
only warns about settings for "may_reset" and "unknown" apps.
"""

from __future__ import annotations

import re
import shlex

# Folders whose deletion loses settings, saves or user data.
_DATA_ROOTS = re.compile(
    r"^(/userdata/system/(add-ons|configs|\.config|\.local/share|bua|drl|pro)/[^/]+/?$"
    r"|/userdata/system/(\.config|\.local/share)/?$"
    r"|/userdata/(saves|roms|bios)(/|$)"
    r"|/userdata/system/?$"
    r"|/(\.config|\.local/share)/[^/]+/?$)"
)
# Names of throwaway folders: deleting them is harmless.
_SCRATCH = re.compile(
    r"(^|/|_|-)(tmp|temp|cache|caches|extract\w*|download\w*|work|build|staging|"
    r"squashfs-root|unpack\w*|old|backup|bak)(/|_|-|$)",
    re.I,
)
# Variable names that, when unresolved, almost always mean the app folder.
_DATA_VARS = re.compile(r"^(app_?dir|install_?dir|addon_?dir|target_?dir|dest(_base)?|config_?dir|appdir|app_path)$", re.I)
_FILE_EXT = re.compile(r"\.(appimage|tar|gz|xz|zst|bz2|zip|7z|deb|rpm|sh|py|json|png|jpg|desktop|log|txt|keys)$", re.I)

_ASSIGN = re.compile(r"""^\s*(?:export\s+|local\s+|readonly\s+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$""")
_RM = re.compile(r"(?:^|[;&|({]\s*|\bthen\s+|\bdo\s+|\belse\s+|&&\s*|\|\|\s*)(?:sudo\s+)?rm\s+((?:-[a-zA-Z]+\s+)+)(.+)")
_NESTED = re.compile(
    r"https://(?:raw\.githubusercontent\.com|github\.com)/batocera-unofficial-addons/"
    r"batocera-unofficial-addons/[^\s\"'|;)]+?\.sh"
)
_RUNS = re.compile(r"\|\s*(?:sudo\s+)?(?:ba)?sh\b|\b(?:ba)?sh\s+(?:-s\s+)?<\(|\b(?:ba)?sh\s+-c\s+[\"']?\$\(")
_VAR = re.compile(r"\$(?:\{([A-Za-z_][A-Za-z0-9_]*)([^}]*)\}|([A-Za-z_][A-Za-z0-9_]*))")


def _strip_value(raw: str) -> str:
    raw = raw.split(" #", 1)[0].strip()
    try:
        parts = shlex.split(raw, comments=False)
    except ValueError:
        return raw.strip("\"'")
    return parts[0] if len(parts) == 1 else raw.strip("\"'")


def _variables(script: str) -> dict:
    env = {"HOME": "/userdata/system"}
    for line in script.splitlines():
        m = _ASSIGN.match(line)
        if not m or "$(" in m.group(2) or "`" in m.group(2):
            continue
        name, value = m.group(1), _strip_value(m.group(2))
        # Only the first plain assignment counts; later ones are usually loops.
        env.setdefault(name, value)
    return env


def _expand(text: str, env: dict, depth: int = 0):
    """Expand $VAR / ${VAR} / ${VAR,,}; returns (text, unresolved names)."""
    unresolved = []

    def sub(m):
        name = m.group(1) or m.group(3)
        full = m.group(0)
        if m.group(2) and not m.group(2).startswith((",", "^", ":-")):
            # ${x##*/}, ${x%/*} and similar: an unknown piece of the value.
            unresolved.append(name)
            return "\x00" + name + "\x00"
        if name in env and depth < 6:
            value, more = _expand(env[name], env, depth + 1)
            unresolved.extend(more)
            if ",," in full:
                value = value.lower()
            return value
        unresolved.append(name)
        return "\x00" + name + "\x00"

    return _VAR.sub(sub, text), unresolved


def _targets(args: str):
    args = re.split(r"\s*(?:\|\||&&|;|\||2>|>|\bthen\b|\bfi\b|\bdone\b)\s*", args)[0]
    try:
        return shlex.split(args)
    except ValueError:
        return args.split()


def _classify(path: str, unresolved) -> str | None:
    """Return "data" if deleting `path` loses settings, "maybe" if it might."""
    if not path or path.startswith("-"):
        return None
    if _FILE_EXT.search(path.rstrip("/")) or _SCRATCH.search(path):
        return None
    if path.startswith("/tmp") or path.startswith("/var/tmp") or path.startswith("/dev/"):
        return None
    if "*" in path.rsplit("/", 1)[-1] and not _DATA_ROOTS.match(path.replace("*", "x")):
        return None
    if "\x00" in path:
        names = re.findall(r"\x00([^\x00]+)\x00", path)
        last = path.rstrip("/").rsplit("/", 1)[-1]
        # rm -rf "$dir/${item##*/}" replaces one item inside the app folder.
        if "\x00" in last and path.count("/") >= 4:
            return None
        if path.strip("\x00/") in names:
            # A bare unresolved variable: likely the app folder, but unknown.
            return "maybe" if any(_DATA_VARS.match(n) for n in names) else None
        clean = re.sub(r"\x00[^\x00]+\x00", "x", path)
        if _DATA_ROOTS.match(clean):
            return "data"
        if clean == "x" or clean.startswith("x/"):
            return "maybe" if any(_DATA_VARS.match(n) for n in names) else None
        return None
    return "data" if _DATA_ROOTS.match(path) else None


def analyze(script: str) -> dict:
    env = _variables(script)
    paths, maybe = [], []
    for raw_line in script.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or line.startswith("echo"):
            continue
        for m in _RM.finditer(line):
            flags = m.group(1).replace(" ", "")
            if "r" not in flags.lower():
                continue
            for target in _targets(m.group(2)):
                expanded, unresolved = _expand(target, env)
                kind = _classify(expanded, unresolved)
                shown = expanded.replace("\x00", "$")
                if kind == "data" and shown not in paths:
                    paths.append(shown)
                elif kind == "maybe" and shown not in maybe:
                    maybe.append(shown)
    # Only scripts it runs (curl ... | bash, bash <(curl ...)), not helper
    # scripts it merely downloads as launchers.
    nested = sorted(set(
        m.group(0)
        for line in script.splitlines()
        if _RUNS.search(line) and not line.lstrip().startswith("#")
        for m in _NESTED.finditer(line)
    ))
    nested = [u for u in nested if not re.search(r"_uninstall\.sh$|/bua\.sh$", u)]
    if paths:
        verdict = "may_reset"
    elif maybe:
        verdict = "unknown"
        paths = maybe
    else:
        verdict = "keeps_settings"
    return {"verdict": verdict, "paths": paths[:8], "nested": nested[:8]}


def combine(results) -> dict:
    """Merge the analysis of an installer and the installers it runs."""
    order = {"keeps_settings": 0, "unknown": 1, "may_reset": 2}
    verdict, paths = "keeps_settings", []
    for r in results:
        if not r:
            verdict = max(verdict, "unknown", key=order.get)
            continue
        verdict = max(verdict, r.get("verdict", "unknown"), key=order.get)
        paths += [p for p in r.get("paths", []) if p not in paths]
    return {"verdict": verdict, "paths": paths[:8]}


if __name__ == "__main__":
    import json
    import sys

    for name in sys.argv[1:]:
        with open(name, errors="replace") as fh:
            print(name, json.dumps(analyze(fh.read())))
