#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# download_music.sh
# Baixa playlists do YouTube, organiza em Genero/Artista/Album
# e deixa pronto pro Swing Music.
#
# Uso: ./download_music.sh [arquivo_playlists.txt]
#
# Formato do arquivo:
#   URL|Artista|Album|Genero
#   URL (autodetecta se nao tiver |)
# ============================================================

# ---- Configuracoes ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${1:-$SCRIPT_DIR/playlists.txt}"
MUSIC_ROOT="${MUSIC_ROOT:-/root/musica}"
ARCHIVES_DIR="$SCRIPT_DIR/archives"

mkdir -p "$ARCHIVES_DIR"
STAGING="$(mktemp -d)"
ANALISE=$(mktemp)
trap 'rm -rf "$STAGING" "$ANALISE"' EXIT

# ---- Dependencias ----
command -v yt-dlp >/dev/null || { echo "yt-dlp nao instalado. Rode: pip install yt-dlp"; exit 1; }
command -v python3 >/dev/null || { echo "python3 nao encontrado."; exit 1; }
python3 -c "import mutagen" 2>/dev/null || { echo "Falta mutagen. Rode: pip install mutagen requests"; exit 1; }

if [[ ! -f "$CONFIG" ]]; then
  echo "Arquivo de playlists nao encontrado: $CONFIG"
  echo "Copie playlists.example.txt para playlists.txt e edite."
  exit 1
fi

# ---- Utilitarios ----
separador() {
  printf '%*s\n' 80 '' | tr ' ' '='
}

extrair_id() {
  local url="$1"
  local id
  id=$(echo "$url" | sed 's/.*list=//;s/[&].*//' | sed 's/.*v=//;s/[&].*//' | head -c 40)
  [[ -z "$id" ]] && id="playlist_$(echo "$url" | md5sum | head -c 8)"
  echo "$id"
}

# ============================================================
# FASE 1: ANALISAR PLAYLISTS
# ============================================================
separador
echo "  FASE 1: ANALISANDO PLAYLISTS"
separador

TOTAL_PLAYLISTS=0
declare -A SEEN_URLS

while IFS='|' read -r URL ARTIST ALBUM GENRE || [ -n "${URL:-}" ]; do
  URL="$(echo "$URL" | xargs)"
  [[ -z "$URL" ]] && continue
  [[ "$URL" =~ ^# ]] && continue
  [[ ! "$URL" =~ ^https?:// ]] && continue
  [[ -n "${SEEN_URLS[$URL]:-}" ]] && continue
  SEEN_URLS[$URL]=1

  TOTAL_PLAYLISTS=$((TOTAL_PLAYLISTS + 1))

  printf "  Playlist %2d: %-50s" "$TOTAL_PLAYLISTS" "${URL:0:50}"

  if [[ -z "${ARTIST// }" ]]; then
    FALLBACK=$(extrair_id "$URL")
    echo "  ID: $FALLBACK"
    ARTIST="Desconhecido"
    ALBUM="$FALLBACK"
    TAMANHO=0
    GENRE="auto"
  else
    TAMANHO="?"
    echo "  OK  (usando dados manuais)"
  fi

  ARTIST="$(echo "$ARTIST" | xargs)"
  ALBUM="$(echo "$ALBUM" | xargs)"
  GENRE="$(echo "${GENRE:-auto}" | xargs)"

  # Salva no arquivo de analise: TAMANHO|ARTIST|ALBUM|GENRE|URL
  # Usa "0" como fallback se TAMANHO nao for numero
  if [[ "$TAMANHO" =~ ^[0-9]+$ ]]; then
    printf "%010d|%s|%s|%s|%s\n" "$TAMANHO" "$ARTIST" "$ALBUM" "$GENRE" "$URL" >> "$ANALISE"
  else
    printf "%010d|%s|%s|%s|%s\n" "0" "$ARTIST" "$ALBUM" "$GENRE" "$URL" >> "$ANALISE"
  fi
done < "$CONFIG"

if [[ $TOTAL_PLAYLISTS -eq 0 ]]; then
  echo "  Nenhuma playlist valida encontrada em $CONFIG"
  exit 1
fi

# ---- Ordenar por tamanho (maior primeiro) ----
SORTED=$(sort -t'|' -k1 -rn "$ANALISE" | head -100)

echo ""
separador
echo "  ORDEM DE DOWNLOAD (MAIOR PRIMEIRO)"
separador
printf "  %-3s %-40s %-20s %7s\n" "#" "Playlist" "Artista" "Faixas"
printf "  %-3s %-40s %-20s %7s\n" "---" "----------------------------------------" "--------------------" "-------"

ORDER=0
while IFS='|' read -r TAMANHO ARTIST ALBUM GENRE URL; do
  ORDER=$((ORDER + 1))
  nome="${ALBUM:0:38}"
  artista="${ARTIST:0:18}"
  printf "  %3d %-40s %-20s %7d\n" "$ORDER" "$nome" "$artista" "$((10#$TAMANHO))"
done <<< "$SORTED"

echo ""

# ============================================================
# FASE 2: BAIXAR PLAYLISTS
# ============================================================
separador
echo "  FASE 2: BAIXANDO PLAYLISTS"
separador
echo ""

TOTAL_OK=0
TOTAL_FAIL=0
ORDER=0
FAILED_URLS=()
FAILED_ARTISTS=()
FAILED_ALBUMS=()
FAILED_GENRES=()

while IFS='|' read -r TAMANHO ARTIST ALBUM GENRE URL; do
  ORDER=$((ORDER + 1))

  echo "  [${ORDER}/${TOTAL_PLAYLISTS}] ${ARTIST} - ${ALBUM}"
  echo "  --------------------------------------------------"

  # Prepara diretorio
  SAFE_NAME="$(echo "${ARTIST}_${ALBUM}" | tr ' /' '__')"
  PLAYLIST_DIR="$STAGING/$SAFE_NAME"
  mkdir -p "$PLAYLIST_DIR"

  # Monta argumentos do yt-dlp
  YT_ARGS=(
    -x --audio-format mp3 --audio-quality 0
    --embed-thumbnail
    --no-embed-metadata
    --ignore-errors
    --no-overwrites
    --sleep-interval 2
    --extractor-args "youtube:player_client=android"
    --download-archive "$ARCHIVES_DIR/${SAFE_NAME}.txt"
    -o "$PLAYLIST_DIR/%(playlist_index)03d - %(title)s.%(ext)s"
  )

  # --- Etapa 1: Download ---
  echo "  Etapa 1/2: Baixando audio..."
  if ! yt-dlp "${YT_ARGS[@]}" "$URL" 2>&1 | sed 's/^/    /'; then
    echo "  [ERRO] Download falhou"
    FAILED_URLS+=("$URL")
    FAILED_ARTISTS+=("$ARTIST")
    FAILED_ALBUMS+=("$ALBUM")
    FAILED_GENRES+=("$GENRE")
    TOTAL_FAIL=$((TOTAL_FAIL + 1))
    continue
  fi

  # --- Etapa 2: Tags + Organizar ---
  echo "  Etapa 2/2: Aplicando tags e organizando..."
  if ! python3 "$SCRIPT_DIR/tag_and_sort.py" \
    --input "$PLAYLIST_DIR" \
    --artist "$ARTIST" \
    --album "$ALBUM" \
    --genre "$GENRE" \
    --output "$MUSIC_ROOT" 2>&1 | sed 's/^/    /'; then
    echo "  [ERRO] Falha ao organizar arquivos"
    FAILED_URLS+=("$URL")
    FAILED_ARTISTS+=("$ARTIST")
    FAILED_ALBUMS+=("$ALBUM")
    FAILED_GENRES+=("$GENRE")
    TOTAL_FAIL=$((TOTAL_FAIL + 1))
    continue
  fi

  TOTAL_OK=$((TOTAL_OK + 1))
  echo "  OK: ${ARTIST} - ${ALBUM}"
  echo ""

done <<< "$SORTED"

# ============================================================
# FASE 3: RETENTATIVA
# ============================================================
if [[ ${#FAILED_URLS[@]} -gt 0 ]]; then
  echo ""
  separador
  echo "  FASE 3: RETENTATIVA (${#FAILED_URLS[@]} playlist(s))"
  separador
  echo ""

  RETRY_OK=0
  for i in "${!FAILED_URLS[@]}"; do
    URL="${FAILED_URLS[$i]}"
    ARTIST="${FAILED_ARTISTS[$i]}"
    ALBUM="${FAILED_ALBUMS[$i]}"
    GENRE="${FAILED_GENRES[$i]}"

    echo "  Retentativa: ${ARTIST} - ${ALBUM}"
    echo "  --------------------------------------------------"

    SAFE_NAME="$(echo "${ARTIST}_${ALBUM}" | tr ' /' '__')"
    PLAYLIST_DIR="$STAGING/$SAFE_NAME"
    mkdir -p "$PLAYLIST_DIR"

    YT_ARGS=(
      -x --audio-format mp3 --audio-quality 0
      --embed-thumbnail
      --no-embed-metadata
      --ignore-errors
      --no-overwrites
      --sleep-interval 2
      --extractor-args "youtube:player_client=android"
      --download-archive "$ARCHIVES_DIR/${SAFE_NAME}.txt"
      -o "$PLAYLIST_DIR/%(playlist_index)03d - %(title)s.%(ext)s"
    )

    if yt-dlp "${YT_ARGS[@]}" "$URL" 2>&1 | sed 's/^/    /'; then
      if python3 "$SCRIPT_DIR/tag_and_sort.py" \
        --input "$PLAYLIST_DIR" \
        --artist "$ARTIST" \
        --album "$ALBUM" \
        --genre "$GENRE" \
        --output "$MUSIC_ROOT" 2>&1 | sed 's/^/    /'; then
        TOTAL_OK=$((TOTAL_OK + 1))
        RETRY_OK=$((RETRY_OK + 1))
        echo "  OK na retentativa!"
      else
        TOTAL_FAIL=$((TOTAL_FAIL + 1))
        echo "  [ERRO] Falhou novamente na organizacao"
      fi
    else
      TOTAL_FAIL=$((TOTAL_FAIL + 1))
      echo "  [ERRO] Falhou novamente no download"
    fi
    echo ""
  done
fi

# ============================================================
# SUMARIO FINAL
# ============================================================
echo ""
separador
echo "  SUMARIO FINAL"
separador
echo ""
echo "  Total de playlists processadas: $TOTAL_OK"
echo "  Falhas:                         $TOTAL_FAIL"
echo "  Biblioteca em:                  $MUSIC_ROOT"
echo ""

# ---- Docker ----
if command -v docker >/dev/null && docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^swingmusic$'; then
  echo "  Reiniciando container swingmusic..."
  docker restart swingmusic
  echo "  Container reiniciado"
else
  echo "  Container swingmusic nao encontrado. Reinicie manualmente se necessario:"
  echo "    docker compose restart"
fi

echo ""
echo "  Pronto!"
