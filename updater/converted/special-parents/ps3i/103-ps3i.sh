#!/bin/sh

# ===== BUA parent-source registration adapter =====

bua_parent_identity() {
    python3 "/userdata/system/add-ons/bua/updater/catalog/ps3i_identity.py"
}

if [[ "${BUA_REGISTRATION_ONLY:-0}" == "1" ]]; then
    if ! declare -F bua_register >/dev/null 2>&1; then
        echo "BUA registration helper unavailable." >&2
        exit 1
    fi

    values="$(
        bua_parent_identity
    )" || exit 1

    version="$(
        printf '%s\n' "$values" |
            sed -n '1p'
    )"

    identity="$(
        printf '%s\n' "$values" |
            sed -n '2p'
    )"

    bua_register \
        "$version" \
        "vendor_web" \
        "ps3i" \
        "ps3i.8101987.xyz" \
        "custom" \
        "" \
        "" \
        "" \
        "$identity"

    exit $?
fi

# ===== end BUA parent-source registration adapter =====


# ================= CONFIG =================
INSTALL_DIR="$HOME/.local/ps3i"
BIN_DIR="$HOME/bin"
PSI_URL="https://ps3i.8101987.xyz/ps3i.tar.xz"
TMP_DIR="$(mktemp -d)"
TMP_FILE="${TMP_DIR}/ps3i.tar.xz"
BATO_FLAG=0

# ================= FUNCTIONS =================
cleanup() {
  stty echo icanon 2>/dev/null
  echo ""
}
trap 'cleanup; exit 1' INT TERM

die() {
  tput bold
  tput setaf 1
  printf '[ERROR] %s\n' "$*" >&2
  tput setaf 9
  tput sgr0
  exit 1
}

info() {
  tput bold
  tput setaf 6
  printf '[INFO] %s\n' "$*" >&1
  tput setaf 9
  tput sgr0
}

ask() {
  tput bold
  tput setaf 3
  printf '[INPUT] %s\n' "$*" >&1
  tput setaf 9
  tput sgr0
}

detect_profile() {
  shell_bin=$(basename "$SHELL")

  case "$shell_bin" in
  bash)
    if [ -f "$HOME/.bashrc" ]; then
      echo "$HOME/.bashrc"
    elif [ -f "$HOME/.bash_profile" ]; then
      echo "$HOME/.bash_profile"
    else
      echo "$HOME/.profile"
    fi
    ;;
  zsh)
    echo "$HOME/.zshrc"
    ;;
  ksh)
    echo "$HOME/.kshrc"
    ;;
  fish)
    echo "$HOME/.config/fish/config.fish"
    ;;
  *)
    # POSIX-compliant fallback
    if [ -f "$HOME/.profile" ]; then
      echo "$HOME/.profile"
    else
      # If nothing exists, suggest .profile as a universal profile
      echo "$HOME/.profile"
    fi
    ;;
  esac
}

PROFILE_FILE=$(detect_profile)

# ================= CHECK SYSTEM =================
info "Checking system architecture..."

OS="$(uname -s 2>/dev/null)"
ARCH="$(uname -m 2>/dev/null)"

case "$OS" in
Linux) ;;
*)
  die "This installer supports Linux systems only."
  ;;
esac

case "$ARCH" in
x86_64 | amd64 | aarch64) ;;
*)
  die "Unsupported architecture: $ARCH (64-bit required)."
  ;;
esac

# ================= CREATE DIRECTORIES =================
info "Creating installation directories..."

[ -d "$INSTALL_DIR" ] && rm -rf "$INSTALL_DIR"
[ -d "$INSTALL_DIR" ] || mkdir -p "$INSTALL_DIR" || die "Failed to create $INSTALL_DIR"
[ -d "$BIN_DIR" ] || mkdir -p "$BIN_DIR" || die "Failed to create $BIN_DIR"

# ================= DOWNLOAD SCRIPTS =================
info "Downloading scripts and assets..."

download() {
  url="$1"
  dest="$2"

  if command -v wget >/dev/null 2>&1; then
    wget -qq "$url" -O "$dest" || die "Failed to download $url"
  elif command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$dest" || die "Failed to download $url"
  else
    die "Neither wget nor curl is available."
  fi
}

download "$PSI_URL" "$TMP_FILE"

# ================= EXTRACTION ==================
tar xf "$TMP_FILE" -C "$INSTALL_DIR" --no-same-owner || die "Failed to extract files"

# ================= PERMISSIONS =================
info "Setting executable permission..."

chmod 755 "${INSTALL_DIR}/ps3i" ${INSTALL_DIR}/batocera_menu_entries/* 2>/dev/null ||
  chmod 755 "${INSTALL_DIR}/ps3i" ||
  die "Failed to set permissions"

# ================= SYMLINKS =================
info "Creating symlinks..."

ln -sf "$INSTALL_DIR/ps3i" "$BIN_DIR/ps3i"

# ================= BATOCERA MODE =====================
if batocera-version >/dev/null 2>&1; then
  info "Installing Batocera integrations..."
  mkdir -p /userdata/system/.local/share/file-manager/actions
  /bin/cp --preserve "$INSTALL_DIR/batocera_menu_entries/install-rpcs3.desktop" \
    /userdata/system/.local/share/file-manager/actions/ || die "Could not install desktop entries"
  /bin/cp --preserve "$INSTALL_DIR/batocera_menu_entries/ps3i_menu_entry" \
    /userdata/system/services/ || die "Could not install custom services"
  batocera-services enable ps3i_menu_entry || die "Could not enable custom services"
  /userdata/system/services/ps3i_menu_entry start || die "Could not start custom services"
  BATO_FLAG=1
fi

# ================= STANDARD LINUX MODE ================
if [ "$BATO_FLAG" -eq 0 ]; then
  info "Installing desktop & file manager shortcuts"...
  DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
  APPS_DIR="${DATA_HOME}/applications"
  MIME_DIR="${DATA_HOME}/mime/packages"

  mkdir -p "$APPS_DIR" "$MIME_DIR"

  info "Registering MIME types..."
  cat <<EOF >"$MIME_DIR/ps3i-types.xml"
<?xml version="1.0" encoding="UTF-8"?>
<mime-info xmlns="http://www.freedesktop.org/standards/shared-mime-info">
  <mime-type type="application/x-ps3-pkg">
    <comment>PS3 Package File</comment>
    <glob pattern="*.pkg"/>
    <glob pattern="*.PKG"/>
  </mime-type>
  <mime-type type="application/x-ps3-rap">
    <comment>PS3 RAP License</comment>
    <glob pattern="*.rap"/>
    <glob pattern="*.RAP"/>
  </mime-type>
</mime-info>
EOF

  if command -v update-mime-database >/dev/null 2>&1; then
    update-mime-database "${DATA_HOME}/mime"
  fi

  info "Generating .desktop file..."
  cat <<EOF >"$APPS_DIR/ps3i.desktop"
[Desktop Entry]
Type=Application
Name=ps3i Installer
Comment=Install PS3 PKG and RAP files to RPCS3
Exec="$INSTALL_DIR/ps3i" --gui %F
Icon=$INSTALL_DIR/ps3i.png
Terminal=false
Categories=Utility;System;
MimeType=application/x-ps3-pkg;application/x-ps3-rap;
Actions=Install;

[Desktop Action Install]
Name=Install to RPCS3
Exec="$INSTALL_DIR/ps3i" --gui %F
Icon=$INSTALL_DIR/ps3i.png
EOF

  if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$APPS_DIR"
  fi

  if command -v xdg-user-dir >/dev/null 2>&1; then
    DESKTOP_DIR=$(xdg-user-dir DESKTOP)
    if [ -n "$DESKTOP_DIR" ] && [ -d "$DESKTOP_DIR" ]; then
      info "Creating desktop shortcut..."
      cp "$APPS_DIR/ps3i.desktop" "$DESKTOP_DIR/"
      chmod +x "$DESKTOP_DIR/ps3i.desktop"
    fi
  fi
fi

# ================= PATH SETUP =================
info "Ensuring $BIN_DIR is in PATH..."

PATH_LINE='export PATH="$HOME/bin:$PATH"'

if [ -f "$PROFILE_FILE" ]; then
  if ! grep -q 'export PATH=.*$HOME/bin' "$PROFILE_FILE"; then
    {
      printf '\n# Added by ps3i installer\n'
      printf '%s\n' "$PATH_LINE"
    } >>"$PROFILE_FILE"
  fi
else
  printf '\n%s\n' "$PATH_LINE" >"$PROFILE_FILE"
fi

# ================= DONE =================
info "Installation complete."
info "Restart your shell or source your \"$PROFILE_FILE\"."
