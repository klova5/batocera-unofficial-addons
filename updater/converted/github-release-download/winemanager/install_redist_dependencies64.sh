#!/bin/bash

# ===== BUA updater registration adapter =====
bua_github_release_register() {
    local bua_owner='DRLEdition19'
    local bua_repo='batocera.drl'

    local bua_values

    bua_values=$(
        python3 - "$bua_owner" "$bua_repo" <<'PYBUAGH'
import hashlib
import json
import sys
import urllib.request

owner, repo = sys.argv[1:3]

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
    release = json.loads(
        response.read().decode("utf-8")
    )

tag = str(
    release.get("tag_name") or ""
).strip()

if not tag:
    raise SystemExit(
        "GitHub release has no tag_name"
    )

assets = []

for asset in release.get("assets") or []:
    assets.append({
        "id": asset.get("id"),
        "name": asset.get("name"),
        "size": asset.get("size"),
        "updated_at": asset.get("updated_at"),
    })

identity_payload = {
    "release_id": release.get("id"),
    "release_updated_at": release.get("updated_at"),
    "assets": sorted(
        assets,
        key=lambda a: (
            str(a.get("name") or ""),
            str(a.get("id") or ""),
        ),
    ),
}

serialized = json.dumps(
    identity_payload,
    sort_keys=True,
    separators=(",", ":"),
).encode("utf-8")

digest = hashlib.sha256(
    serialized
).hexdigest()

identity = (
    "github-release:"
    + str(release.get("id") or "unknown")
    + ":"
    + digest
)

print(tag)
print(identity)
PYBUAGH
    ) || return 1

    local bua_version
    local bua_identity

    bua_version=$(
        printf '%s\n' "$bua_values" |
            sed -n '1p'
    )

    bua_identity=$(
        printf '%s\n' "$bua_values" |
            sed -n '2p'
    )

    if [[ -z "$bua_version" || -z "$bua_identity" ]]; then
        echo "Unable to determine GitHub release identity." >&2
        return 1
    fi

    bua_register \
        "$bua_version" \
        "github_release" \
        "$bua_owner" \
        "$bua_repo" \
        "custom" \
        "" \
        "" \
        "" \
        "$bua_identity"
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


# Diretório onde os executáveis serão armazenados
WINE_EXE_DIR="/userdata/system/wine/exe"

# Criar o diretório se não existir
mkdir -p "$WINE_EXE_DIR"

# Função para baixar e extrair arquivos
download_and_extract() {
    local url=$1
    local output_dir=$2
    local filename=$(basename "$url")
    
    # Baixar o arquivo
    wget -P "$output_dir" "$url"
    
    # Se for um arquivo .7z, extrair
    if [[ "$filename" == *.7z ]]; then
        7zr x "$output_dir/$filename" -o"$output_dir"
        rm "$output_dir/$filename"
    fi
}

# Baixar e extrair DirectX3D
echo "Baixando e extraindo DirectX3D..."
download_and_extract "https://github.com/DRLEdition19/batocera.drl/releases/download/Batocera_Appimages/directx.7z" "$WINE_EXE_DIR"

# Baixar Visual C++ Redistributable 2015-2019
echo "Baixando Visual C++ Redistributable 2015-2019..."
wget -P "$WINE_EXE_DIR" "https://github.com/DRLEdition19/batocera.drl/releases/download/Batocera_Appimages/vcredist_x64_2015_2019.exe"

# Baixar Visual C++ Redistributable 2019
echo "Baixando Visual C++ Redistributable 2019..."
wget -P "$WINE_EXE_DIR" "https://github.com/DRLEdition19/batocera.drl/releases/download/Batocera_Appimages/vcredist_x64_2019.exe"

# Baixar Visual C++ Redistributable 2017
echo "Baixando Visual C++ Redistributable 2017..."
wget -P "$WINE_EXE_DIR" "https://github.com/DRLEdition19/batocera.drl/releases/download/Batocera_Appimages/vcredist_x64_2017.exe"

# Baixar Visual C++ Redistributable 2015
echo "Baixando Visual C++ Redistributable 2015..."
wget -P "$WINE_EXE_DIR" "https://github.com/DRLEdition19/batocera.drl/releases/download/Batocera_Appimages/vcredist_x64_2015.exe"

# Baixar Visual C++ Redistributable 2013
echo "Baixando Visual C++ Redistributable 2013..."
wget -P "$WINE_EXE_DIR" "https://github.com/DRLEdition19/batocera.drl/releases/download/Batocera_Appimages/vcredist_x64_2013.exe"

# Baixar Visual C++ Redistributable 2012
echo "Baixando Visual C++ Redistributable 2012..."
wget -P "$WINE_EXE_DIR" "https://github.com/DRLEdition19/batocera.drl/releases/download/Batocera_Appimages/vcredist_x64_2012.exe"

# Baixar Visual C++ Redistributable 2010
echo "Baixando Visual C++ Redistributable 2010..."
wget -P "$WINE_EXE_DIR" "https://github.com/DRLEdition19/batocera.drl/releases/download/Batocera_Appimages/vcredist_x64_2010.exe"

# Baixar Visual C++ Redistributable 2008
echo "Baixando Visual C++ Redistributable 2008..."
wget -P "$WINE_EXE_DIR" "https://github.com/DRLEdition19/batocera.drl/releases/download/Batocera_Appimages/vcredist_x64_2008.exe"

# Baixar Visual C++ Redistributable 2005
echo "Baixando Visual C++ Redistributable 2005..."
wget -P "$WINE_EXE_DIR" "https://github.com/DRLEdition19/batocera.drl/releases/download/Batocera_Appimages/vcredist_x64_2005.exe"

echo "Todos os arquivos foram baixados e extraídos para $WINE_EXE_DIR."


# ===== BUA post-install registration =====
if declare -F bua_register >/dev/null 2>&1; then
    bua_github_release_register || true
fi
# ===== end BUA post-install registration =====

