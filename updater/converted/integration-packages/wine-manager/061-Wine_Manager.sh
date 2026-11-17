#!/bin/bash

# ===== BUA integration registration adapter =====

bua_integration_identity() {
    python3 - <<'PYBUAWM'
import json
import urllib.request

owner = "Gr3gorywolf"
repo = "batocera_wine_manager"

api = (
    "https://api.github.com/repos/"
    + owner
    + "/"
    + repo
    + "/releases/latest"
)

req = urllib.request.Request(
    api,
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
    release = json.loads(
        response.read().decode("utf-8")
    )

tag = str(
    release.get("tag_name") or ""
).strip()

if not tag:
    raise SystemExit(
        "Unable to determine Wine Manager release tag"
    )

asset_url = ""

for asset in release.get("assets") or []:
    name = str(asset.get("name") or "")
    if name == "batocera_wine_manager.zip":
        asset_url = str(
            asset.get("browser_download_url") or ""
        ).strip()
        break

if not asset_url:
    raise SystemExit(
        "Wine Manager release asset not found"
    )

print(tag)
print("wine-manager:" + tag)
print(asset_url)
PYBUAWM
}

if [[ "${BUA_REGISTRATION_ONLY:-0}" == "1" ]]; then
    if ! declare -F bua_register >/dev/null 2>&1; then
        echo "BUA registration helper unavailable." >&2
        exit 1
    fi

    values="$(
        bua_integration_identity
    )" || exit 1

    version="$(
        printf '%s\n' "$values" |
            sed -n '1p'
    )"

    identity="$(
        printf '%s\n' "$values" |
            sed -n '2p'
    )"

    url="$(
        printf '%s\n' "$values" |
            sed -n '3p'
    )"

    bua_register \
        "$version" \
        "github_release" \
        "Gr3gorywolf" \
        "batocera_wine_manager" \
        "custom" \
        "" \
        "" \
        "" \
        "$identity" \
        "" \
        "" \
        "" \
        "" \
        "" \
        "" \
        "" \
        "" \
        "$url"

    exit $?
fi

# ===== end BUA integration registration adapter =====


# Mensagem de boas-vindas
echo "Seja bem vindo ao instalador automático do Wine Manager by DRL Edition."

# Diretório temporário para download
TEMP_DIR="/userdata/tmp/winemanager"
DRL_FILE="$TEMP_DIR/winemanager.zip"
DEST_DIR="/userdata/"

# Cria o diretório temporário
echo "Criando diretório temporário para download..."
mkdir -p $TEMP_DIR

# Faz o download do arquivo drl 
echo "Fazendo download do arquivo winemanager.drl..."
curl -L -o $DRL_FILE "https://github.com/DRLEdition19/batocera-unofficial-addons.add/raw/refs/heads/main/winemanager/extra/winemanager.zip"

# Extrai o arquivo drl com barra de progresso e altera permissões de cada arquivo extraído
echo "Extraindo o arquivo drl e definindo permissões para cada arquivo..."
unzip -o $DRL_FILE -d $TEMP_DIR | while IFS= read -r file; do
    if [ -f "$TEMP_DIR/$file" ]; then
        chmod 777 "$TEMP_DIR/$file"
    fi
done

# Copia os arquivos extraídos para o diretório raiz, substituindo os existentes
echo "Copiando arquivos extraídos para o diretório raiz..."
cp -r $TEMP_DIR/* $DEST_DIR

# Limpa o diretório temporário
echo "Limpando diretório temporário..."
rm -rf $TEMP_DIR

# Exclui o arquivo winemanager.drl do diretório raiz
echo "Excluindo o arquivo winemanager.drl do diretório raiz..."
rm -f /userdata/winemanager.zip

echo "Instalação concluída com sucesso."
