# BUA updater package

Source for `bua-updater-x86_64.tar.gz`, the release asset that adds the
version-aware Updater screen to Batocera Unofficial Add-ons (PR #166).

The BUA repository itself only carries two small changes:

- `app/install_x86_new.sh` downloads this asset from the official release
  `updater-v2` and installs it only if its SHA256 matches the one pinned
  in the script.
- `app/bua_installerx86.py` gets three hook points and
  `load_updater_package()`, which loads `updater/bua_updater_overlay.py`
  when the package is installed. Without it BUA runs exactly as before;
  a package that fails to load is rolled back.

## Build

```
python3 build_bundle.py
```

The build is reproducible: the same `updater/` tree always gives the same
bytes, so anyone can rebuild the asset and compare its SHA256 with the
one pinned in `install_x86_new.sh`.

## Release

1. Build, then create the release `updater-v2` on
   batocera-unofficial-addons/batocera-unofficial-addons and upload
   `dist/bua-updater-x86_64.tar.gz` as its asset.
2. A new package version: publish it under a new tag (`updater-v3`, ...),
   then update the URL and SHA256 in both places in the BUA repo:
   `BUA_UPDATER_URL` / `BUA_UPDATER_SHA256` in `app/install_x86_new.sh`
   and `UPDATER_PACKAGE_URL` / `UPDATER_PACKAGE_SHA256` in
   `app/bua_installerx86.py`. Installed copies update the next time BUA
   opens.

## Contents

- `updater/bua_updater_overlay.py`: Updater screen, version and installer
  checks, update methods, hooks.
- `updater/catalog/`: update recipes, global manifest builder, Switch
  verification, GitHub API cache, reinstall safety check.
- `updater/converted/`: registration-aware installer adapters.
- `updater/integrations/`: optional Switch/Citron Nextendo integration.
- `updater/translation/`: the updater's strings in all 8 languages.
- `updater/tools/bua_update_audit.py`: mock-updates every app and reports
  any that cannot be updated.
- `updater/install.py`: post-install step run by `install_x86_new.sh`.
