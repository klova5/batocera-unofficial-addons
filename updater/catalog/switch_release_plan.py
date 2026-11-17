#!/usr/bin/env python3
"""Pure Switch release-to-installation comparison. Does not download/install.

Unknown/opaque release identities must never be treated as newer. For a
composite package, every component must be comparable (same or newer), so
an incomplete update cannot falsely register all five versions as installed.
"""
import json
import re

COMPONENT_NAMES=("Citron","Eden","Eden PGO","Eden Nightly","Ryujinx-Nextendo")

def installed_components(display):
    if not isinstance(display,str):
        raise ValueError("Installed Switch component version unavailable")
    out={}
    for item in display.split("; "):
        found=[name for name in sorted(COMPONENT_NAMES,key=len,reverse=True)
               if item.startswith(name+" ")]
        if not found:
            raise ValueError("Installed Switch component identity unrecognized")
        name=found[0]
        value=item[len(name)+1:].strip()
        if not value or name in out:
            raise ValueError("Incomplete or duplicate installed Switch component")
        out[name]=value
    if set(out)!=set(COMPONENT_NAMES):
        raise ValueError("Missing installed Switch component baseline")
    return out

def compare_component(name,old,new):
    if not isinstance(old,str) or not isinstance(new,str) or not old or not new:
        return None
    if old==new:
        return 0
    if name=="Citron":
        # Git commit hashes have no chronological ordering.
        return None
    if name in ("Eden","Eden PGO","Ryujinx-Nextendo"):
        m1=re.fullmatch(r"v?(\d+)\.(\d+)\.(\d+)",old)
        m2=re.fullmatch(r"v?(\d+)\.(\d+)\.(\d+)",new)
        if not (m1 and m2):
            return None
        a,b=tuple(map(int,m1.groups())),tuple(map(int,m2.groups()))
        return (b>a)-(b<a)
    if name=="Eden Nightly":
        m1=re.fullmatch(r"v(\d{6,15})\.([0-9a-f]+)",old)
        m2=re.fullmatch(r"v(\d{6,15})\.([0-9a-f]+)",new)
        if not (m1 and m2):
            return None
        a,b=int(m1.group(1)),int(m2.group(1))
        if a==b:
            return None # Same timestamp but different build hash
        return (b>a)-(b<a)
    return None

def select_switch_update(installed_display,registration,verify_components,*,major=42,architecture="x86_64",raw_components=None):
    if not isinstance(registration,dict):
        raise ValueError("No current Switch registration")
    upstream=registration.get("upstream") or {}
    if not isinstance(upstream,dict) or (upstream.get("type"),upstream.get("repo")) != ("multi_parent","switch-components"):
        raise ValueError("Switch source must be its current multi-parent adapter")
    recipe=registration.get("update_recipe") or {}
    if not isinstance(recipe,dict) or recipe.get("type")!="multi_component" or recipe.get("target")!="/userdata/system/switch/appimages":
        raise ValueError("Unexpected Switch update recipe")
    components=recipe.get("components")
    if not isinstance(components,list):
        raise ValueError("Switch component metadata missing")
    # The BUA normalizer adds default 'type'/'executable' fields, which are
    # NOT in the original Switch SHA256 payload. Use the raw registration
    # components when available from registration-only stdout, then compare
    # that attested component list against normalized registration exactly.
    raw=raw_components if raw_components is not None else components
    if not isinstance(raw,list):
        raise ValueError("Raw Switch release metadata is missing")
    lines=[registration.get("app_version"),registration.get("update_identity"),
           "multi_parent","switch-components",json.dumps(raw,separators=(",",":"))]
    verified=verify_components(lines,major=major,architecture=architecture)
    by_name={c.get("name"):c for c in components if isinstance(c,dict)}
    if len(by_name)!=5 or len(components)!=5:
        raise ValueError("Normalized Switch component entries do not match release")
    for checked in verified["components"]:
        normalized=by_name.get(checked["name"])
        if not isinstance(normalized,dict):
            raise ValueError("Normalized Switch component missing")
        for key in ("name","version","url","target"):
            if normalized.get(key)!=checked.get(key):
                raise ValueError("Normalized Switch component changed: "+checked["name"])
        if normalized.get("type","replace_file")!="replace_file":
            raise ValueError("Unexpected component recipe type")
        if normalized.get("executable",True) != checked["executable"]:
            raise ValueError("Normalized Switch executable flag changed")
    installed=installed_components(installed_display)
    pending=[]
    for component in verified["components"]:
        name=component["name"]
        result=compare_component(name,installed[name],component["version"])
        if result is None:
            raise ValueError("Unorderable release for "+name+"; manual verification required")
        if result<0:
            raise ValueError("An older release was offered for "+name)
        if result>0:
            pending.append(dict(component))
    return {"status":"update_available" if pending else "current",
            "needs_update":bool(pending),"version":verified["display_version"],
            "update_identity":verified["identity"],
            "components":pending,
            "all_verified_components":verified["components"],
            "registration":registration}
