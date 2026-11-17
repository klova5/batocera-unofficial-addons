#!/bin/bash

# ===== BUA Android/BlissOS variant registration adapter =====

BUA_ANDROID_STATE_DIR="/userdata/system/configs/bat-drl/Android"
BUA_ANDROID_VARIANT_FILE="${BUA_ANDROID_STATE_DIR}/bua-variant.json"

bua_android_variant_metadata() {
    local variant="$1"

    case "$variant" in
        blissos16-generic)
            printf '%s\n' \
                "16.9.7" \
                "https://sinalbr.dl.sourceforge.net/project/blissos-x86/Official/BlissOS16/Gapps/Generic/Bliss-v16.9.7-x86_64-OFFICIAL-gapps-20241011.iso?viasf=1"
            ;;

        blissos16-go)
            printf '%s\n' \
                "16.9.7" \
                "https://sinalbr.dl.sourceforge.net/project/blissos-x86/Official/BlissOS16/Gapps/Go/Bliss-Go-v16.9.7-x86_64-OFFICIAL-gapps-20241012.iso?viasf=1"
            ;;

        *)
            return 1
            ;;
    esac
}


bua_android_identity() {
    local variant="$1"

    python3 - "$variant" <<'PYBUAANDROID'
import hashlib
import html
import re
import sys
import urllib.request

variant = sys.argv[1]

variants = {
    "blissos16-generic": {
        "page": (
            "https://sourceforge.net/projects/"
            "blissos-x86/files/Official/"
            "BlissOS16/Gapps/Generic/"
        ),
        "pattern": re.compile(
            r'Bliss-v'
            r'([0-9]+\.[0-9]+\.[0-9]+)'
            r'-x86_64-OFFICIAL-gapps-'
            r'([0-9]{8})\.iso'
        ),
    },

    "blissos16-go": {
        "page": (
            "https://sourceforge.net/projects/"
            "blissos-x86/files/Official/"
            "BlissOS16/Gapps/Go/"
        ),
        "pattern": re.compile(
            r'Bliss-Go-v'
            r'([0-9]+\.[0-9]+\.[0-9]+)'
            r'-x86_64-OFFICIAL-gapps-'
            r'([0-9]{8})\.iso'
        ),
    },
}

config = variants.get(
    variant
)

if not config:
    raise SystemExit(
        f"Unknown Android variant: {variant}"
    )

req = urllib.request.Request(
    config["page"],
    headers={
        "User-Agent": "Mozilla/5.0 BUA-Updater",
        "Cache-Control": "no-cache",
    },
)

with urllib.request.urlopen(
    req,
    timeout=25,
) as response:
    text = response.read().decode(
        "utf-8",
        errors="replace",
    )

text = html.unescape(text)

def version_key(value):
    return tuple(
        int(part)
        for part in value.split(".")
    )

found = []

for match in config["pattern"].finditer(text):
    version = match.group(1)
    build_date = match.group(2)
    filename = match.group(0)

    found.append(
        (
            version_key(version),
            build_date,
            version,
            filename,
        )
    )

if not found:
    raise SystemExit(
        "Unable to determine latest BlissOS "
        f"release for {variant}"
    )

found.sort(
    reverse=True
)

_, build_date, version, filename = (
    found[0]
)

payload = "\n".join(
    [
        variant,
        version,
        build_date,
        filename,
    ]
).encode("utf-8")

digest = hashlib.sha256(
    payload
).hexdigest()

identity = (
    "sourceforge:"
    + variant
    + ":"
    + version
    + ":"
    + build_date
    + ":"
    + digest
)

print(version)
print(identity)
PYBUAANDROID
}


bua_android_register_variant() {
    local variant="$1"
    local values
    local version
    local identity

    values="$(
        bua_android_identity "$variant"
    )" || return 1

    version="$(
        printf '%s\n' "$values" |
            sed -n '1p'
    )"

    identity="$(
        printf '%s\n' "$values" |
            sed -n '2p'
    )"

    [[ -n "$version" ]] || return 1
    [[ -n "$identity" ]] || return 1

    bua_register \
        "$version" \
        "sourceforge" \
        "BlissOS" \
        "blissos-x86" \
        "custom" \
        "" \
        "" \
        "" \
        "$identity" \
        "$variant"
}


bua_android_read_saved_variant() {
    [[ -f "$BUA_ANDROID_VARIANT_FILE" ]] || return 1

    python3 - "$BUA_ANDROID_VARIANT_FILE" <<'PYBUAANDROIDSTATE'
import json
import sys

try:
    with open(sys.argv[1]) as f:
        data = json.load(f)

    variant = str(
        data.get("variant_id") or ""
    ).strip()

    if variant:
        print(variant)

except Exception:
    pass
PYBUAANDROIDSTATE
}


bua_android_save_variant() {
    local variant="$1"
    local values
    local version
    local url

    values="$(
        bua_android_variant_metadata "$variant"
    )" || return 1

    version="$(
        printf '%s\n' "$values" |
            sed -n '1p'
    )"

    url="$(
        printf '%s\n' "$values" |
            sed -n '2p'
    )"

    mkdir -p "$BUA_ANDROID_STATE_DIR"

    python3 - \
        "$BUA_ANDROID_VARIANT_FILE" \
        "$variant" \
        "$version" \
        "$url" <<'PYBUAANDROIDSAVE'
import json
import os
import sys

path, variant, version, url = sys.argv[1:5]

data = {
    "variant_id": variant,
    "app_version": version,
    "source_url": url,
}

tmp = path + ".tmp"

with open(tmp, "w") as f:
    json.dump(
        data,
        f,
        indent=2,
        sort_keys=True,
    )
    f.write("\n")

os.replace(
    tmp,
    path,
)
PYBUAANDROIDSAVE
}


if [[ "${BUA_REGISTRATION_ONLY:-0}" == "1" ]]; then
    if ! declare -F bua_register >/dev/null 2>&1; then
        echo "BUA registration helper unavailable." >&2
        exit 1
    fi

    variant="${BUA_INSTALLED_VARIANT:-}"

    if [[ -z "$variant" ]]; then
        variant="$(
            bua_android_read_saved_variant
        )"
    fi

    if [[ -z "$variant" ]]; then
        echo "Android installed variant is unknown." >&2
        exit 2
    fi

    bua_android_register_variant "$variant"
    exit $?
fi

# ===== end BUA Android/BlissOS variant registration adapter =====

# Exibe mensagem inicial 
echo "Presenting..."
sleep 2

# Limpa o terminal
#clear

# Função para exibir data e hora atual
show_current_time() {
    echo -e "Current Date and Time (UTC): $(date '+%Y-%m-%d %H:%M:%S')"
    echo
}

# Função para animação de digitação
type_text() {
    text="$1"
    for ((i=0; i<${#text}; i++)); do
        echo -n "${text:$i:1}"
        sleep 0.05
    done
    echo
}

# Códigos de cores ANSI
blue="\e[34m"   # cor final: azul
reset="\e[0m"

# Vetor expandido com 15 cores em degradê
colors=(
    "\e[38;5;196m"  # Vermelho vivo
    "\e[38;5;202m"  # Laranja escuro
    "\e[38;5;208m"  # Laranja
    "\e[38;5;214m"  # Laranja claro
    "\e[38;5;220m"  # Amarelo
    "\e[38;5;226m"  # Amarelo brilhante
    "\e[38;5;190m"  # Verde-amarelado
    "\e[38;5;118m"  # Verde claro
    "\e[38;5;46m"   # Verde
    "\e[38;5;48m"   # Verde água
    "\e[38;5;51m"   # Ciano
    "\e[38;5;45m"   # Azul claro
    "\e[38;5;39m"   # Azul
    "\e[38;5;63m"   # Azul-violeta
    "\e[38;5;129m"  # Violeta
)

# Arte ASCII do DRL Edition
ascii_art=(
"██████╗ ██████╗  ██╗         ███████╗██████╗ ██╗████████╗██╗ ██████╗ ███╗   ██╗"
"██╔══██╗██╔══██╗ ██║         ██╔════╝██╔══██╗██║╚══██╔══╝██║██╔═══██╗████╗  ██║"
"██║  ██║██████╔╝ ██║         █████╗  ██║  ██║██║   ██║   ██║██║   ██║██╔██╗ ██║"
"██║  ██║██╔══██╗ ██║         ██╔══╝  ██║  ██║██║   ██║   ██║██║   ██║██║╚██╗██║"
"██████╔╝██║  ██║ ███████╗    ███████╗██████╔╝██║   ██║   ██║╚██████╔╝██║ ╚████║"
"╚═════╝ ╚═╝  ╚═╝ ╚══════╝    ╚══════╝╚═════╝ ╚═╝   ╚═╝   ╚═╝ ╚═════╝ ╚═╝  ╚═══╝"
)

# Animação da arte ASCII com efeito degradê
for ((k=0; k<3; k++)); do  # 3 ciclos completos
    for ((i=0; i<${#colors[@]}; i++)); do
        clear
        # Mostra data e hora 
        show_current_time
        
        # Mostra a arte ASCII na cor atual do degradê
        for line in "${ascii_art[@]}"; do
            echo -e "${colors[$i]}${line}${reset}"
        done
        sleep 0.1
    done
done

# Mostra a versão final em azul
clear
show_current_time
for line in "${ascii_art[@]}"; do
    echo -e "${blue}${line}${reset}"
done

# Pula uma linha
echo ""

# Mensagem final com animação de digitação
echo -ne "${PURPLE}"  # Cor roxa para a mensagem final
type_text "Thank you for running this script!"  
type_text "Developed by DRLEdition19"  
type_text "Acknowledgements: KevoBatoYT"
type_text "The installation will start in a few moments. Please wait..."
sleep 2
clear


# Welcome message
echo "Welcome to the automatic installer for the Android 5.6.2 by DRL Edition."

# Temporary directory for download
TEMP_DIR="/userdata/tmp/Android"
DRL_FILE="$TEMP_DIR/Android.DRL"
EXTRACT_DIR="$TEMP_DIR/extracted"
ADDON_DIR="/userdata/system/add-ons/android-bua"
PORTS_DIR="/userdata/roms/ports"
GAMELIST_PATH="${PORTS_DIR}/gamelist.xml"
BACKUP_PATH="${PORTS_DIR}/gamelist.xml.bak"
APP_NAME="Android"
APP_EXEC="Android"
PORT_SCRIPT_PATH="${PORTS_DIR}/${APP_EXEC}.sh"
PORT_SCRIPT_NAME="${APP_EXEC}.sh"
DEST_FILE="/userdata/system/configs/bat-drl/Android/Android.iso"
URL_ISO_GE16="https://sinalbr.dl.sourceforge.net/project/blissos-x86/Official/BlissOS16/Gapps/Generic/Bliss-v16.9.7-x86_64-OFFICIAL-gapps-20241011.iso?viasf=1"
URL_ISO_GO14="https://sinalbr.dl.sourceforge.net/project/blissos-x86/Official/BlissOS14/OpenGApps/Go/Bliss-Go-v14.10.3-x86_64-OFFICIAL-opengapps-20241012.iso?viasf=1"
URL_ISO_GO16="https://sinalbr.dl.sourceforge.net/project/blissos-x86/Official/BlissOS16/Gapps/Go/Bliss-Go-v16.9.7-x86_64-OFFICIAL-gapps-20241012.iso?viasf=1"

GAMELIST_ENTRY_CONTENT="	<game>
		<path>./${PORT_SCRIPT_NAME}</path>
		<name>${APP_NAME}</name>
		<desc>=========================================
Info: ${APP_NAME} for Batocera
Developer: DRL Edition 19
Acknowledgements: KevoBatoYT
=========================================</desc>
		<image>./images/${APP_EXEC}-thumb.png</image>
		<marquee>./images/${APP_EXEC}-marquee.png</marquee>
		<thumbnail>./images/${APP_EXEC}-thumb.png</thumbnail>
		<fanart>./images/${APP_EXEC}-thumb.png</fanart>
		<titleshot>./images/${APP_EXEC}-thumb.png</titleshot>
		<cartridge>./images/${APP_EXEC}-thumb.png</cartridge>
		<boxart>./images/${APP_EXEC}-marquee.png</boxart>
		<boxback>./images/${APP_EXEC}-thumb.png</boxback>
		<wheel>./images/${APP_EXEC}-thumb.png</wheel>
		<mix>./images/${APP_EXEC}-thumb.png</mix>
		<rating>1</rating>
		<developer>DRL Edition</developer>
		<publisher>DRL Edition</publisher>
		<players>1</players>
		<favorite>true</favorite>
		<lang>en</lang>
		<sortname>1 =- ${APP_NAME}</sortname>
		<genreid>Android For Batocera</genreid>
		<screenshot>./images/${APP_EXEC}-thumb.png</screenshot>
	</game>"

# Function to create backup
create_backup() {
    if [ -f "$GAMELIST_PATH" ]; then
        cp -rf "$GAMELIST_PATH" "$BACKUP_PATH"
        echo "gamelist.xml backup created at: $BACKUP_PATH"
    fi
}

# Function to create new gamelist.xml
create_new_gamelist() {
    echo "Creating new gamelist.xml file..."
    cat > "$GAMELIST_PATH" << EOF
<?xml version="1.0"?>
<gameList>
${GAMELIST_ENTRY_CONTENT}
</gameList>
EOF
    echo "gamelist.xml file created successfully!"
}

# Function to check if the entry already exists
check_entry() {
    if [ -f "$GAMELIST_PATH" ]; then
        grep -q "<path>./${PORT_SCRIPT_NAME}</path>" "$GAMELIST_PATH"
        return $?
    else
        return 1
    fi
}

# Function to remove the existing entry (using awk)
remove_entry() {
    echo "Removing existing entry..."
    TEMP_FILE=$(mktemp)
    awk -v script_name="${PORT_SCRIPT_NAME}" '
        BEGIN { game_block = ""; in_game = 0; is_target = 0; }
        /<game>/ { in_game = 1; game_block = $0; is_target = 0; }
        in_game && ! /<game>/ { game_block = game_block "\n" $0 }
        in_game && $0 ~ "<path>./" script_name "</path>" { is_target = 1 }
        /<\/game>/ {
            if (!is_target) { print game_block }
            in_game = 0; game_block = "";
            next
        }
        !in_game { print }
    ' "$GAMELIST_PATH" > "$TEMP_FILE"
    mv "$TEMP_FILE" "$GAMELIST_PATH"
    echo "Existing entry removed."
}

# Function to add the entry (using awk)
add_entry() {
    echo "Adding new entry..."
    TEMP_FILE=$(mktemp)
    awk -v entry="${GAMELIST_ENTRY_CONTENT}" '
        /<\/gameList>/ { print entry }
        { print }
    ' "$GAMELIST_PATH" > "$TEMP_FILE"
    mv "$TEMP_FILE" "$GAMELIST_PATH"
    echo "New entry added."
}

# Create the temporary directories
echo "Creating temporary directories..."
mkdir -p "$TEMP_DIR"
mkdir -p "$EXTRACT_DIR"
mkdir -p "$ADDON_DIR/bin"
mkdir -p "$ADDON_DIR/lib"
mkdir -p "$PORTS_DIR"
mkdir -p "/userdata/system/configs/bat-drl/Android"
mkdir -p "/userdata/system/configs/android/applications"
clear

# Download the DRL file

echo # Blank line for better readability

# Function that encapsulates the entire selection and download process.
# This avoids code repetition.
start_download_process() {
    clear

    # Use dialog for version selection
    choice=$(dialog --stdout --title "Android Version Selection" --menu \
        "Which version of Android would you like to install?" 15 70 2 \
        "1" "BlissOS 16 Generic Version (Recommended for most hardware)" \
        "2" "BlissOS 16 GO Version (Optimized for low-end hardware)")

    # If user cancelled, default to option 1
    if [ -z "$choice" ]; then
        choice=1
    fi

    # Defines variables based on the user's choice
    case "$choice" in
        1)
            echo "You have selected the BlissOS 16 Generic Version."
            URL=$URL_ISO_GE16
            BUA_SELECTED_VARIANT="blissos16-generic"
            ;;
        2)
            echo "You have selected the BlissOS 16 GO Version."
            URL=$URL_ISO_GO16
            BUA_SELECTED_VARIANT="blissos16-go"
            ;;
    esac
    
    echo # Blank line for clarity
    echo "Starting download of: $DEST_FILE"
    sleep 4

    # Downloads the file using the defined URL and filename
    if curl -L -o "$DEST_FILE" "$URL"; then
        echo "Download completed successfully!"

        if [[ -n "${BUA_SELECTED_VARIANT:-}" ]]; then
            bua_android_save_variant                 "$BUA_SELECTED_VARIANT" || true
        fi
    else
        echo "ERROR: An error occurred during the download."
        echo "The script cannot continue without the file. Exiting."
        # exit 1 # Uncomment this line to make the script stop in case of an error.
    fi
}

# --- MAIN VERIFICATION LOGIC ---
# The script now looks for ANY of the defined ISO files.
echo "Checking for local ISO files..."
sleep 2

if [ -f "$DEST_FILE" ]; then
    # If one or more files are found...
    echo "A ISO installation file was already found."

    # Use dialog to ask if user wants to re-download
    if dialog --stdout --title "Android Installation" --yesno \
        "An ISO installation file was already found.\n\nDo you want to remove the existing file and download a new one?" 10 60; then
        echo "Removing existing files..."
        rm -f "$DEST_FILE"
        echo "Files removed. Starting download process..."
        sleep 2
        start_download_process # Calls the download function
    else
        echo "Keeping the existing file. Download will be skipped."
        echo "Continuing installation with file: $DEST_FILE"
        sleep 4
    fi
else
    # If NO file is found, it starts the download process directly.
    echo "No local installation file was found."
    echo "The download process will be initiated."
    sleep 3
    start_download_process # Calls the download function
fi

clear
echo "Downloading Android addon..."
curl -L -o "$DRL_FILE" "https://github.com/DRLEdition19/DRLEdition_Interface/releases/download/files/Android_5.6.2.DRL"

# Check if download was successful
if [ ! -f "$DRL_FILE" ]; then
    echo "Error: Failed to download DRL file"
    exit 1
fi

# Extract the squashfs file
echo "Extracting..."
unsquashfs -f -d "$EXTRACT_DIR" "$DRL_FILE"

# Check if extraction was successful
if [ $? -ne 0 ]; then
    echo "Error: Failed to extract DRL file"
    rm -rf "$TEMP_DIR"
    exit 1
fi


# gamelist.xml Update
echo "Updating gamelist.xml..."
if [ ! -f "$GAMELIST_PATH" ] || [ ! -s "$GAMELIST_PATH" ]; then
    create_new_gamelist
else
    create_backup
    if check_entry; then
        remove_entry
    fi
    add_entry
fi
echo "Gamelist.xml updated."
clear

# Install binaries and libraries — symlinks.sh picks these up automatically
echo "Installing binaries and libraries..."
[ -d "$EXTRACT_DIR/usr/bin" ] && cp -r "$EXTRACT_DIR/usr/bin/." "$ADDON_DIR/bin/" || true
[ -d "$EXTRACT_DIR/usr/lib" ] && cp -r "$EXTRACT_DIR/usr/lib/." "$ADDON_DIR/lib/" || true

# Desktop entries go to userdata config dir, restored each boot via custom.sh
echo "Installing desktop entries..."
[ -d "$EXTRACT_DIR/usr/share/applications" ] && \
    cp -r "$EXTRACT_DIR/usr/share/applications/." "/userdata/system/configs/android/applications/" || true

# userdata content goes directly to /userdata (already persistent)
echo "Installing userdata files..."
[ -d "$EXTRACT_DIR/userdata" ] && cp -r "$EXTRACT_DIR/userdata/." /userdata/ 2>/dev/null || true

# Limpeza
echo "Cleaning up..."
rm -rf "$TEMP_DIR"

# Write desktop entry restore script
echo "Installing desktop entry restore script..."
cat << 'RESTOREEOF' > /userdata/system/configs/android/restore-desktop-entries.sh
#!/bin/bash
SRC="/userdata/system/configs/android/applications"
DEST="/usr/share/applications"
[ -d "$SRC" ] || exit 0
for f in "$SRC"/*.desktop; do
    [ -f "$f" ] || continue
    cp "$f" "$DEST/"
done
RESTOREEOF
chmod +x /userdata/system/configs/android/restore-desktop-entries.sh

# Hook into custom.sh
CUSTOM_SH="/userdata/system/custom.sh"
RESTORE_LINE="bash /userdata/system/configs/android/restore-desktop-entries.sh"
if ! grep -q "restore-desktop-entries.sh" "$CUSTOM_SH" 2>/dev/null; then
    echo "$RESTORE_LINE" >> "$CUSTOM_SH"
    chmod +x "$CUSTOM_SH"
fi

# Run restore now for current session
bash /userdata/system/configs/android/restore-desktop-entries.sh

clear
echo "Installation completed successfully."
echo "Android 5.6.2 by DRL Edition"

if declare -F bua_register >/dev/null 2>&1; then
    variant="${BUA_SELECTED_VARIANT:-}"

    if [[ -z "$variant" ]]; then
        variant="$(
            bua_android_read_saved_variant
        )"
    fi

    if [[ -n "$variant" ]]; then
        bua_android_register_variant             "$variant" || true
    fi
fi

exit 0
