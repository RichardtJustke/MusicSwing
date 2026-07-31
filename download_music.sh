#!/usr/bin/env bash
set -u

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

# ---- PATH & Virtualenv ----
for p in "$SCRIPT_DIR/venv/bin" "$HOME/venv-yt/bin" "$HOME/.local/bin"; do
  if [[ -d "$p" ]]; then
    export PATH="$p:$PATH"
  fi
done

CONFIG="${1:-$SCRIPT_DIR/playlists.txt}"
if [[ -w "/root/musica" || ( ! -e "/root/musica" && -w "/root" ) ]]; then
  DEFAULT_MUSIC_ROOT="/root/musica"
else
  DEFAULT_MUSIC_ROOT="$SCRIPT_DIR/musica"
fi
MUSIC_ROOT="${MUSIC_ROOT:-$DEFAULT_MUSIC_ROOT}"
COOKIES="${COOKIES:-$SCRIPT_DIR/cookies.txt}"
if [[ -f "$COOKIES" ]]; then
  if yt-dlp --no-check-certificates --cookies "$COOKIES" "https://www.youtube.com/watch?v=B1kJ9RnHZ9o" --simulate 2>&1 | grep -q -i "cookies are no longer valid"; then
    echo "  [AVISO] $COOKIES contem cookies expirados do YouTube!"
    echo "  [AVISO] Ignorando cookies expirados para evitar bloqueios de bot pelo YouTube."
    COOKIES=""
  fi
fi
ARCHIVES_DIR="$SCRIPT_DIR/archives"
LOG_FILE="$SCRIPT_DIR/download.log"

mkdir -p "$ARCHIVES_DIR"
STAGING="$(mktemp -d)"
ANALISE=$(mktemp)
# Ignora fechamento do terminal/SSH (SIGHUP) para nao interromper a execucao
trap '' HUP
trap 'rm -rf "$STAGING" "$ANALISE"' EXIT

# Log de tudo que rodar (terminal + arquivo)
exec > >(tee "$LOG_FILE")
exec 2>&1

# ---- Dependencias ----
command -v yt-dlp >/dev/null || { echo "yt-dlp nao instalado. Rode: pip install yt-dlp"; exit 1; }
command -v python3 >/dev/null || { echo "python3 nao encontrado."; exit 1; }
python3 -c "import mutagen" 2>/dev/null || { echo "Falta mutagen. Rode: pip install mutagen requests"; exit 1; }

# JS runtime para resolver JS challenges do YouTube (Node ou Deno)
if ! command -v deno &>/dev/null && ! command -v node &>/dev/null; then
  echo "  Nenhum JS runtime (Node/Deno) encontrado. Tentando instalar Deno..."
  curl -fsSL https://deno.land/install.sh | sh -s -- -y 2>&1 | tail -1 || true
  export DENO_INSTALL="$HOME/.deno"
  export PATH="$DENO_INSTALL/bin:$PATH"
fi
if [[ -d "$HOME/.deno/bin" ]] && ! command -v deno &>/dev/null; then
  export PATH="$HOME/.deno/bin:$PATH"
fi

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
    ARTIST="Desconhecido"
    ALBUM="$FALLBACK"
    GENRE="auto"

    # Detecta tamanho da playlist via yt-dlp
    echo -n " ID: $FALLBACK"
    TAMANHO=$(yt-dlp --flat-playlist --print id --ignore-errors --no-check-certificates \
      ${COOKIES:+--cookies "$COOKIES"} \
      "$URL" 2>/dev/null | wc -l | tr -d ' ')
    if [[ -z "$TAMANHO" || "$TAMANHO" -eq 0 ]]; then
      TAMANHO="?"
      echo ""
    else
      echo " ($TAMANHO faixas)"
    fi
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

# ---- Ordenar por tamanho (menor primeiro) ----
SORTED=$(sort -t'|' -k1 -n "$ANALISE" | head -100)

echo ""
separador
echo "  ORDEM DE DOWNLOAD (MENOR PRIMEIRO)"
separador
printf "  %-3s %-38s %-18s %7s %10s\n" "#" "Playlist" "Artista" "Faixas" "Estimado"
printf "  %-3s %-38s %-18s %7s %10s\n" "---" "--------------------------------------" "------------------" "-------" "----------"

TOTAL_EST_SEG=0
ORDER=0
while IFS='|' read -r TAMANHO ARTIST ALBUM GENRE URL; do
  ORDER=$((ORDER + 1))
  nome="${ALBUM:0:36}"
  artista="${ARTIST:0:16}"

  if [[ "$((10#$TAMANHO))" -gt 0 ]]; then
    seg=$(( (10#$TAMANHO) * 1 ))
    TOTAL_EST_SEG=$((TOTAL_EST_SEG + seg))
    if [[ "$seg" -ge 3600 ]]; then
      est=$(printf "%dh%02dm" $((seg / 3600)) $(( (seg % 3600) / 60 )))
    elif [[ "$seg" -ge 60 ]]; then
      est=$(printf "%dm%02ds" $((seg / 60)) $((seg % 60)))
    else
      est="${seg}s"
    fi
  else
    est="?"
  fi

  printf "  %3d %-38s %-18s %7d %10s\n" "$ORDER" "$nome" "$artista" "$((10#$TAMANHO))" "$est"
done <<< "$SORTED"

if [[ "$TOTAL_EST_SEG" -gt 0 ]]; then
  if [[ "$TOTAL_EST_SEG" -ge 3600 ]]; then
    total_est=$(printf "%dh%02dm" $((TOTAL_EST_SEG / 3600)) $(( (TOTAL_EST_SEG % 3600) / 60 )))
  else
    total_est=$(printf "%dm%02ds" $((TOTAL_EST_SEG / 60)) $((TOTAL_EST_SEG % 60)))
  fi
  echo ""
  echo "  Tempo estimado total: $total_est (~1s/faixa + overhead)"
fi

echo ""

## ============================================================
# FASE 2: BAIXANDO PLAYLISTS
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
FAILED_REASONS=()

extrair_motivo_erro() {
  local log_file="$1"
  if grep -q -i "Sign in to confirm you’re not a bot" "$log_file"; then
    echo "Bloqueio de Bot do YouTube (Sign in to confirm you're not a bot)"
  elif grep -q -i "The provided YouTube account cookies are no longer valid" "$log_file"; then
    echo "Cookies do YouTube expirados ou inválidos"
  elif grep -q -i "Private video" "$log_file" || grep -q -i "is private" "$log_file"; then
    echo "Playlist ou vídeo marcado como privado"
  elif grep -q -i "does not exist" "$log_file"; then
    echo "Playlist não existe ou foi removida"
  elif grep -q -i "HTTP Error 429" "$log_file"; then
    echo "Rate limit do YouTube atingido (HTTP 429)"
  else
    local err_line
    err_line=$(grep "ERROR:" "$log_file" | head -n 1 | sed 's/.*ERROR:\s*//')
    if [[ -n "$err_line" ]]; then
      echo "$err_line"
    else
      echo "Nenhum MP3 baixado (Erro desconhecido na extração)"
    fi
  fi
}

while IFS='|' read -r TAMANHO ARTIST ALBUM GENRE URL; do
  ORDER=$((ORDER + 1))

  echo "  [${ORDER}/${TOTAL_PLAYLISTS}] ${ARTIST} - ${ALBUM}"
  echo "  --------------------------------------------------"

  # Prepara diretorio
  SAFE_NAME="$(echo "${ARTIST}_${ALBUM}" | tr ' /' '__')"
  PLAYLIST_DIR="$STAGING/$SAFE_NAME"
  YT_LOG=$(mktemp)
  mkdir -p "$PLAYLIST_DIR"

  # Monta argumentos do yt-dlp
  YT_ARGS=(
    -x --audio-format mp3 --audio-quality 0
    --embed-thumbnail
    --no-embed-metadata
    --ignore-errors
    --no-overwrites
    --no-check-certificates
    -N 4
    --sleep-requests 1.5
    --extractor-args "youtube:player_client=android,mweb"
    --exec "after_move:python3 '$SCRIPT_DIR/tag_and_sort.py' --file {} --artist '$ARTIST' --album '$ALBUM' --genre '$GENRE' --output '$MUSIC_ROOT'"
    --remote-components ejs:github
    --download-archive "$ARCHIVES_DIR/${SAFE_NAME}.txt"
    -o "$PLAYLIST_DIR/%(playlist_index)03d - %(title)s.%(ext)s"
  )

  if command -v node &>/dev/null; then
    YT_ARGS+=(--js-runtimes node)
  elif command -v deno &>/dev/null; then
    YT_ARGS+=(--js-runtimes deno)
  fi

  if [[ -n "${COOKIES:-}" && -f "$COOKIES" ]]; then
    YT_ARGS+=(--cookies "$COOKIES")
  fi

  # --- Etapa 1: Download ---
  echo "  Etapa 1/2: Baixando audio..."
  yt-dlp "${YT_ARGS[@]}" "$URL" 2>&1 | tee "$YT_LOG" | sed 's/^/    /' || true

  HAS_MP3=$(find "$PLAYLIST_DIR" -maxdepth 1 -name "*.mp3" 2>/dev/null | wc -l)
  if [[ "$HAS_MP3" -eq 0 ]]; then
    if grep -q -i "has already been recorded in the archive" "$YT_LOG"; then
      rm -f "$YT_LOG"
      TOTAL_OK=$((TOTAL_OK + 1))
      echo "  [OK] Playlist já totalmente baixada (faixas já existentes na biblioteca)"
      echo ""
      continue
    fi
    MOTIVO=$(extrair_motivo_erro "$YT_LOG")
    rm -f "$YT_LOG"
    echo ""
    echo "  [ERRO CRÍTICO] Falha ao baixar playlist: ${ARTIST} - ${ALBUM}"
    echo "  [MOTIVO] $MOTIVO"
    echo ""
    FAILED_URLS+=("$URL")
    FAILED_ARTISTS+=("$ARTIST")
    FAILED_ALBUMS+=("$ALBUM")
    FAILED_GENRES+=("$GENRE")
    FAILED_REASONS+=("$MOTIVO")
    TOTAL_FAIL=$((TOTAL_FAIL + 1))
    continue
  fi
  rm -f "$YT_LOG"

  # --- Etapa 2: Tags + Organizar ---
  echo "  Etapa 2/2: Aplicando tags e organizando..."
  python3 "$SCRIPT_DIR/tag_and_sort.py" \
    --input "$PLAYLIST_DIR" \
    --artist "$ARTIST" \
    --album "$ALBUM" \
    --genre "$GENRE" \
    --output "$MUSIC_ROOT" 2>&1 | sed 's/^/    /'
  TAGS_EXIT="${PIPESTATUS[0]:-1}"

  if [[ "$TAGS_EXIT" -ne 0 ]]; then
    MOTIVO="Falha ao organizar tags com tag_and_sort.py (Exit code: $TAGS_EXIT)"
    echo ""
    echo "  [ERRO CRÍTICO] $MOTIVO"
    echo ""
    FAILED_URLS+=("$URL")
    FAILED_ARTISTS+=("$ARTIST")
    FAILED_ALBUMS+=("$ALBUM")
    FAILED_GENRES+=("$GENRE")
    FAILED_REASONS+=("$MOTIVO")
    TOTAL_FAIL=$((TOTAL_FAIL + 1))
    continue
  fi

  TOTAL_OK=$((TOTAL_OK + 1))
  echo "  [OK] Sucesso: ${ARTIST} - ${ALBUM}"
  echo ""

done <<< "$SORTED"

# ============================================================
# FASE 3: RETENTATIVA
# ============================================================
STILL_FAILED_URLS=()
STILL_FAILED_ARTISTS=()
STILL_FAILED_ALBUMS=()
STILL_FAILED_REASONS=()

if [[ ${#FAILED_URLS[@]} -gt 0 ]]; then
  echo ""
  separador
  echo "  FASE 3: RETENTATIVA (${#FAILED_URLS[@]} playlist(s) com falhas)"
  separador
  echo ""

  TOTAL_FAIL=0
  for i in "${!FAILED_URLS[@]}"; do
    URL="${FAILED_URLS[$i]}"
    ARTIST="${FAILED_ARTISTS[$i]}"
    ALBUM="${FAILED_ALBUMS[$i]}"
    GENRE="${FAILED_GENRES[$i]}"

    echo "  Retentativa [$((i + 1))/${#FAILED_URLS[@]}]: ${ARTIST} - ${ALBUM}"
    echo "  --------------------------------------------------"

    SAFE_NAME="$(echo "${ARTIST}_${ALBUM}" | tr ' /' '__')"
    PLAYLIST_DIR="$STAGING/$SAFE_NAME"
    YT_LOG=$(mktemp)
    mkdir -p "$PLAYLIST_DIR"

    YT_ARGS=(
      -x --audio-format mp3 --audio-quality 0
      --embed-thumbnail
      --no-embed-metadata
      --ignore-errors
      --no-overwrites
      --no-check-certificates
      -N 4
      --sleep-requests 1.5
      --extractor-args "youtube:player_client=android,mweb"
      --exec "after_move:python3 '$SCRIPT_DIR/tag_and_sort.py' --file {} --artist '$ARTIST' --album '$ALBUM' --genre '$GENRE' --output '$MUSIC_ROOT'"
      --remote-components ejs:github
      --download-archive "$ARCHIVES_DIR/${SAFE_NAME}.txt"
      -o "$PLAYLIST_DIR/%(playlist_index)03d - %(title)s.%(ext)s"
    )

    if command -v node &>/dev/null; then
      YT_ARGS+=(--js-runtimes node)
    elif command -v deno &>/dev/null; then
      YT_ARGS+=(--js-runtimes deno)
    fi

    # Tenta retentativa sem cookies caso cookies antigos tenham causado falha por auth/bot block
    yt-dlp "${YT_ARGS[@]}" "$URL" 2>&1 | tee "$YT_LOG" | sed 's/^/    /' || true

    HAS_MP3=$(find "$PLAYLIST_DIR" -maxdepth 1 -name "*.mp3" 2>/dev/null | wc -l)
    if [[ "$HAS_MP3" -gt 0 ]]; then
      python3 "$SCRIPT_DIR/tag_and_sort.py" \
        --input "$PLAYLIST_DIR" \
        --artist "$ARTIST" \
        --album "$ALBUM" \
        --genre "$GENRE" \
        --output "$MUSIC_ROOT" 2>&1 | sed 's/^/    /'
      TAGS_EXIT="${PIPESTATUS[0]:-1}"
      if [[ "$TAGS_EXIT" -eq 0 ]]; then
        TOTAL_OK=$((TOTAL_OK + 1))
        echo "  [OK RETENTATIVA] Sucesso na retentativa!"
      else
        MOTIVO="Falha ao aplicar tags na retentativa (Exit: $TAGS_EXIT)"
        TOTAL_FAIL=$((TOTAL_FAIL + 1))
        STILL_FAILED_URLS+=("$URL")
        STILL_FAILED_ARTISTS+=("$ARTIST")
        STILL_FAILED_ALBUMS+=("$ALBUM")
        STILL_FAILED_REASONS+=("$MOTIVO")
        echo "  [ERRO RETENTATIVA] $MOTIVO"
      fi
    else
      if grep -q -i "has already been recorded in the archive" "$YT_LOG"; then
        TOTAL_OK=$((TOTAL_OK + 1))
        echo "  [OK RETENTATIVA] Playlist já totalmente baixada anteriormente"
      else
        MOTIVO=$(extrair_motivo_erro "$YT_LOG")
        TOTAL_FAIL=$((TOTAL_FAIL + 1))
        STILL_FAILED_URLS+=("$URL")
        STILL_FAILED_ARTISTS+=("$ARTIST")
        STILL_FAILED_ALBUMS+=("$ALBUM")
        STILL_FAILED_REASONS+=("$MOTIVO")
        echo "  [ERRO RETENTATIVA] $MOTIVO"
      fi
    fi
    rm -f "$YT_LOG"
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
echo "  Total de playlists com sucesso: $TOTAL_OK"
echo "  Total de playlists com falha:   $TOTAL_FAIL"
echo "  Biblioteca de música em:        $MUSIC_ROOT"
echo ""

if [[ ${#STILL_FAILED_URLS[@]} -gt 0 ]]; then
  separador
  echo "  DETALHES DAS FALHAS (${#STILL_FAILED_URLS[@]} playlist(s))"
  separador
  for i in "${!STILL_FAILED_URLS[@]}"; do
    echo "  [$((i+1))] ${STILL_FAILED_ARTISTS[$i]} - ${STILL_FAILED_ALBUMS[$i]}"
    echo "      URL:    ${STILL_FAILED_URLS[$i]}"
    echo "      MOTIVO: ${STILL_FAILED_REASONS[$i]}"
    echo ""
  done
  echo "  Log completo salvo em: $LOG_FILE"
  echo ""
fi

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
