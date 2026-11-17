#!/bin/bash

# ===== BUA updater registration adapter =====
bua_github_release_register() {
    local bua_values

    bua_values=$(
        python3 <<'PYBUAWIN'
import hashlib
import json
import re
import urllib.request

owner = "DRLEdition19"
repo = "DRLEdition_Interface"

url = (
    "https://api.github.com/repos/"
    f"{owner}/{repo}/releases/latest"
)

req = urllib.request.Request(
    url,
    headers={
        "User-Agent": "BUA-Updater",
        "Accept": "application/vnd.github+json",
        "Cache-Control": "no-cache",
    },
)

with urllib.request.urlopen(
    req,
    timeout=25,
) as response:
    release = json.load(response)

candidates = []

for asset in release.get("assets") or []:
    name = str(asset.get("name") or "")
    download_url = str(
        asset.get("browser_download_url") or ""
    )

    m = re.fullmatch(
        r"Winconfig_Files_full_"
        r"([0-9]+(?:\.[0-9]+)*)\.DRL",
        name,
        re.I,
    )

    if not m or not download_url:
        continue

    version = m.group(1)

    key = tuple(
        int(x)
        for x in version.split(".")
    )

    candidates.append(
        (
            key,
            version,
            name,
            download_url,
            asset,
        )
    )

if not candidates:
    raise SystemExit(
        "No current Winconfig full payload asset found"
    )

_candidates = sorted(
    candidates,
    key=lambda item: item[0],
)

_key, version, name, download_url, asset = _candidates[-1]

identity_payload = {
    "release_id": release.get("id"),
    "asset_id": asset.get("id"),
    "asset_name": name,
    "asset_size": asset.get("size"),
    "asset_updated_at": asset.get("updated_at"),
}

digest = hashlib.sha256(
    json.dumps(
        identity_payload,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
).hexdigest()

identity = (
    "winconfig:"
    + version
    + ":"
    + digest
)

print(version)
print(identity)
print(download_url)
PYBUAWIN
    ) || return 1

    local bua_version
    local bua_identity
    local bua_payload_url

    bua_version=$(
        printf '%s\n' "$bua_values" |
            sed -n '1p'
    )

    bua_identity=$(
        printf '%s\n' "$bua_values" |
            sed -n '2p'
    )

    bua_payload_url=$(
        printf '%s\n' "$bua_values" |
            sed -n '3p'
    )

    if [[ -z "$bua_version" || -z "$bua_identity" || -z "$bua_payload_url" ]]; then
        echo "Unable to determine Winconfig parent payload." >&2
        return 1
    fi

    bua_register \
        "$bua_version" \
        "github_release" \
        "DRLEdition19" \
        "DRLEdition_Interface" \
        "custom" \
        "" \
        "" \
        "" \
        "$bua_identity" \
        "" \
        "" \
        "" \
        "" \
        "" \
        "" \
        "" \
        "" \
        "$bua_payload_url"
}


if [[ "${BUA_REGISTRATION_ONLY:-0}" == "1" ]]; then
    if ! declare -F bua_register >/dev/null 2>&1; then
        echo "BUA registration helper is unavailable." >&2
        exit 1
    fi

    bua_github_release_register
    exit $?
fi
# ===== end BUA updater registration adapter =====

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
type_text "The installation will start in a few moments. Please wait..."
sleep 2
clear


# Welcome message
echo "Welcome to the automatic installer for the Winconfig by DRL Edition."

# Temporary directory for download
TEMP_DIR="/userdata/tmp/Winconfig"
DRL_FILE="$TEMP_DIR/Winconfig.DRL"
EXTRACT_DIR="$TEMP_DIR/extracted"
PORTS_DIR="/userdata/roms/ports"
ADDON_BIN="/userdata/system/add-ons/winconfig/bin"
DEPS_INSTALLER="- Windows Game Fix.sh"

# Create the temporary directories
echo "Creating temporary directories..."
mkdir -p $TEMP_DIR
mkdir -p $EXTRACT_DIR
mkdir -p $PORTS_DIR

# Download the DRL file
echo "Downloading the DRL file..."
curl -L -o $DRL_FILE "https://github.com/DRLEdition19/DRLEdition_Interface/releases/download/files/Winconfig_Files_full_6.5.DRL"

# Check if download was successful
if [ ! -f "$DRL_FILE" ]; then
    echo "Error: Failed to download DRL file"
    exit 1
fi

# Extract the squashfs file
echo "Extracting the DRL file..."
unsquashfs -f -d "$EXTRACT_DIR" "$DRL_FILE"

# Check if extraction was successful
if [ $? -ne 0 ]; then
    echo "Error: Failed to extract the DRL file"
    rm -rf $TEMP_DIR
    exit 1
fi

# Find and copy the Winconfig installer
echo "Looking for Winconfig installer..."
FOUND_INSTALLER=$(find "$EXTRACT_DIR" -type f -name "$DEPS_INSTALLER")
if [ ! -z "$FOUND_INSTALLER" ]; then
    echo "Found Winconfig installer. Copying to ports directory..."
    cp -rf "$FOUND_INSTALLER" "$PORTS_DIR/"
    chmod 755 "$PORTS_DIR/$DEPS_INSTALLER"
    echo "Winconfig installer copied successfully to $PORTS_DIR"
else
    echo "Warning: Winconfig installer not found in the extracted files"
fi

# Copy persistent userdata contents (port launchers, configs, binaries)
echo "Installing addon files..."
cp -r "$EXTRACT_DIR/userdata/." /userdata/

# Place usr/bin files in add-ons dir for symlinks.sh to pick up
mkdir -p "$ADDON_BIN"
cp "$EXTRACT_DIR/usr/bin/"* "$ADDON_BIN/"
chmod +x "$ADDON_BIN/"*

# Set permissions for specific files
echo "Setting permissions for specific files..."
chmod 777 /userdata/system/configs/bat-drl/AntiMicroX/antimicrox
chmod 777 /userdata/system/configs/bat-drl/AntiMicroX/antimicrox.sh

# Clean up
echo "Cleaning up..."
rm -rf $TEMP_DIR

echo "Installation completed successfully."

# Gamelist config
# Script para baixar, renomear, configurar permissões e mover um arquivo
# para o diretório do sistema

echo "Iniciando o processo de download e instalação..."

# Download do arquivo
echo "Baixando o arquivo..."
wget -O /tmp/gamelistconfig.sh https://github.com/DRLEdition19/DRLEdition_Interface/raw/refs/heads/main/extra/Winconfig_gamelist_config.sh
echo "Download concluído com sucesso."

# Configura as permissões
echo "Configurando permissões (chmod 777)..."
chmod 777 /tmp/gamelistconfig.sh

# Inicia a ferramenta para configurar o Idioma
xterm -fs 14 -fg white -bg black -fa "Monospace" -en UTF-8 -sb -rightbar -e bash -c "PS1='[\u@\h \$PWD]# ' /bin/bash /tmp/gamelistconfig.sh"

rm -r -f /tmp/gamelistconfig.sh

exit 0


# ===== BUA post-install registration =====
if declare -F bua_register >/dev/null 2>&1; then
    bua_github_release_register || true
fi
# ===== end BUA post-install registration =====

