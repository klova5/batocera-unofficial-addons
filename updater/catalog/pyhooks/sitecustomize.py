"""Loaded automatically by python3 when this folder is on PYTHONPATH (set
by the BUA registration helper): routes GitHub API requests made by
registration adapters through the updater's shared cache."""
import importlib.machinery
import importlib.util
import os
import sys

_here = os.path.dirname(os.path.abspath(__file__))
_catalog = os.path.dirname(_here)

try:
    if _catalog not in sys.path:
        sys.path.append(_catalog)
    import bua_github_api

    bua_github_api.install()
except Exception:
    pass

# Keep any other sitecustomize on the path working.
try:
    _others = [p for p in sys.path if os.path.abspath(p or ".") != _here]
    _spec = importlib.machinery.PathFinder.find_spec("sitecustomize", _others)
    if _spec and _spec.origin and os.path.dirname(_spec.origin) != _here:
        _module = importlib.util.module_from_spec(_spec)
        _spec.loader.exec_module(_module)
except Exception:
    pass
