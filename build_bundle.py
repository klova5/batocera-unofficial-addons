"""Build bua-updater-x86_64.tar.gz reproducibly (same input -> same bytes).
usage: build_bundle.py [OUT]   (default dist/bua-updater-x86_64.tar.gz)
Packs updater/ as it is in this branch."""
import gzip, io, os, sys, tarfile
here = os.path.dirname(os.path.abspath(__file__))
src = os.path.join(here, "updater")
out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(here, "dist", "bua-updater-x86_64.tar.gz")
files = []
for root, dirs, names in os.walk(src):
    dirs[:] = sorted(d for d in dirs if d not in ("__pycache__", ".ruff_cache", ".git"))
    for n in sorted(names):
        if n.endswith(".pyc"):
            continue
        p = os.path.join(root, n)
        files.append((os.path.relpath(p, src), p))
files.sort()
buf = io.BytesIO()
with tarfile.open(fileobj=buf, mode="w", format=tarfile.PAX_FORMAT) as tar:
    dirs = set()
    for rel, _ in files:
        parts = rel.split("/")[:-1]
        for i in range(1, len(parts) + 1):
            dirs.add("/".join(parts[:i]))
    entries = [("updater", None)] + [(f"updater/{d}", None) for d in sorted(dirs)] + [(f"updater/{r}", p) for r, p in files]
    for name, path in entries:
        info = tarfile.TarInfo(name)
        info.mtime = 0; info.uid = info.gid = 0; info.uname = info.gname = "root"
        if path is None:
            info.type = tarfile.DIRTYPE; info.mode = 0o755
            tar.addfile(info)
        else:
            data = open(path, "rb").read()
            info.size = len(data)
            info.mode = 0o755 if os.access(path, os.X_OK) or name.endswith((".sh",)) else 0o644
            tar.addfile(info, io.BytesIO(data))
with open(out, "wb") as fh:
    with gzip.GzipFile(filename="", mode="wb", fileobj=fh, mtime=0, compresslevel=9) as gz:
        gz.write(buf.getvalue())
import hashlib
print(len(files), "files")
print("sha256", hashlib.sha256(open(out, "rb").read()).hexdigest())
