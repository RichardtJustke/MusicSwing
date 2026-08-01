#!/usr/bin/env bash
set -u

# ============================================================
# download_music.sh — MusicSwing Downloader v2.5
# Baixa playlists do YouTube, aplica metadados limpos e
# sincroniza automaticamente ao vivo com o servidor VPS.
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---- Cores & Formatação ANSI ----
BOLD="\033[1m"
DIM="\033[2m"
RESET="\033[0m"

CYAN="\033[1;36m"
MAGENTA="\033[1;35m"
BLUE="\033[1;34m"
GREEN="\033[1;32m"
YELLOW="\033[1;33m"
RED="\033[1;31m"
WHITE="\033[1;37m"

banner() {
  echo -e "${MAGENTA}"
  echo "  ███╗   ███╗██║   ██║███████╗██║██████╗ ███████╗██║███╗   ██╗██████╗ "
  echo "  ████╗ ████║██║   ██║██╔════╝██║██╔════╝ ██╔════╝██║████╗  ██║██╔════╝ "
  echo "  ██╔████╔██║██║   ██║███████╗██║██║      ███████╗██║██╔██╗ ██║██║  ███╗"
  echo "  ██║╚██╔╝██║██║   ██║╚════██║██║██║      ╚════██║██║██║╚██╗██║██║   ██║"
  echo "  ██║ ╚═╝ ██║╚██████╔╝███████║██║╚██████╗ ███████║██║██║ ╚████║╚██████╔╝"
  echo "  ╚═╝     ╚═╝ ╚═════╝ ╚══════╝╚═╝ ╚═════╝ ╚══════╝╚═╝╚═╝  ╚═══╝ ╚═════╝ "
  echo -e "${CYAN}                 🎵 Downloader & Auto-Sync Server v2.5 🚀${RESET}\n"
}

# ---- PATH & Virtualenv ----
for p in "$SCRIPT_DIR/venv/bin" "$HOME/venv-yt/bin" "$HOME/.local/bin"; do
  if [[ -d "$p" ]]; then
    export PATH="$p:$PATH"
  fi
done

USE_OAUTH2="${USE_OAUTH2:-false}"
CONFIG=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --oauth2)
      USE_OAUTH2=true
      shift
      ;;
    *)
      CONFIG="$1"
      shift
      ;;
  esac
done

CONFIG="${CONFIG:-$SCRIPT_DIR/playlists.txt}"

if [[ -w "/root/musica" || ( ! -e "/root/musica" && -w "/root" ) ]]; then
  DEFAULT_MUSIC_ROOT="/root/musica"
  SERVER_SYNC=""
else
  DEFAULT_MUSIC_ROOT="$SCRIPT_DIR/musica"
  SERVER_SYNC="${SERVER_SYNC:-oracle24:/home/ubuntu/musica}"
fi
MUSIC_ROOT="${MUSIC_ROOT:-$DEFAULT_MUSIC_ROOT}"
COOKIES="${COOKIES:-$SCRIPT_DIR/cookies.txt}"

banner

if [[ -n "$SERVER_SYNC" ]]; then
  echo -e "${GREEN}  ✔ Sincronização ao vivo para a VPS ativa:${RESET} ${CYAN}${SERVER_SYNC}${RESET}\n"
fi

if [[ -f "$COOKIES" && "$USE_OAUTH2" != "true" ]]; then
  if yt-dlp --no-check-certificates --cookies "$COOKIES" "https://www.youtube.com/watch?v=B1kJ9RnHZ9o" --simulate 2>&1 | grep -q -i "cookies are no longer valid"; then
    echo -e "${YELLOW}  [AVISO] Cookies expirados no arquivo cookies.txt${RESET}"
    COOKIES=""
  fi
fi

ARCHIVES_DIR="$SCRIPT_DIR/archives"
LOG_FILE="$SCRIPT_DIR/download.log"

mkdir -p "$ARCHIVES_DIR"
STAGING="$(mktemp -d)"
ANALISE=$(mktemp)

trap '' HUP
trap 'rm -rf "$STAGING" "$ANALISE"' EXIT

exec > >(tee "$LOG_FILE")
exec 2>&1

# ---- Dependencias ----
command -v python3 >/dev/null || { echo -e "${RED}[ERRO] Python3 não encontrado.${RESET}"; exit 1; }

if ! command -v yt-dlp >/dev/null || ! python3 -c "import mutagen" 2>/dev/null; then
  echo -e "${CYAN}  [INFO] Instalando dependências (yt-dlp / mutagen)...${RESET}"
  python3 -m venv "$SCRIPT_DIR/venv" || { echo -e "${RED}[ERRO] Falha ao criar venv.${RESET}"; exit 1; }
  "$SCRIPT_DIR/venv/bin/pip" install --upgrade pip yt-dlp mutagen requests yt-dlp-youtube-oauth2 2>&1 | tail -n 3
  export PATH="$SCRIPT_DIR/venv/bin:$PATH"
fi

if [[ -f "$SCRIPT_DIR/venv/bin/pip" ]]; then
  export PATH="$SCRIPT_DIR/venv/bin:$PATH"
  "$SCRIPT_DIR/venv/bin/pip" install -q yt-dlp-youtube-oauth2 2>/dev/null || true
fi

if ! command -v deno &>/dev/null && ! command -v node &>/dev/null; then
  export DENO_INSTALL="$HOME/.deno"
  export PATH="$DENO_INSTALL/bin:$PATH"
fi

if [[ ! -f "$CONFIG" ]]; then
  echo -e "${RED}[ERRO] Arquivo de playlists não encontrado: $CONFIG${RESET}"
  exit 1
fi

separador() {
  echo -e "${BLUE}==============================================================================${RESET}"
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
echo -e "${MAGENTA}${BOLD}   🔍 FASE 1: ANALISANDO & ORDENANDO PLAYLISTS${RESET}"
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

  printf "  ${CYAN}Playlist %2d:${RESET} %-48s" "$TOTAL_PLAYLISTS" "${URL:0:48}"

  if [[ -z "${ARTIST// }" ]]; then
    FALLBACK=$(extrair_id "$URL")
    ARTIST="Desconhecido"
    ALBUM="$FALLBACK"
    GENRE="auto"

    echo -n " ID: $FALLBACK"
    TAMANHO=$(yt-dlp --flat-playlist --print id --ignore-errors --no-check-certificates \
      ${COOKIES:+--cookies "$COOKIES"} \
      "$URL" 2>/dev/null | wc -l | tr -d ' ')
    if [[ -z "$TAMANHO" || "$TAMANHO" -eq 0 ]]; then
      TAMANHO="?"
      echo ""
    else
      echo -e " (${GREEN}${TAMANHO} faixas${RESET})"
    fi
  else
    TAMANHO="?"
    echo -e " ${GREEN}✔ OK (dados manuais)${RESET}"
  fi

  ARTIST="$(echo "$ARTIST" | xargs)"
  ALBUM="$(echo "$ALBUM" | xargs)"
  GENRE="$(echo "${GENRE:-auto}" | xargs)"

  if [[ "$TAMANHO" =~ ^[0-9]+$ ]]; then
    printf "%010d|%s|%s|%s|%s\n" "$TAMANHO" "$ARTIST" "$ALBUM" "$GENRE" "$URL" >> "$ANALISE"
  else
    printf "%010d|%s|%s|%s|%s\n" "0" "$ARTIST" "$ALBUM" "$GENRE" "$URL" >> "$ANALISE"
  fi
done < "$CONFIG"

if [[ $TOTAL_PLAYLISTS -eq 0 ]]; then
  echo -e "${RED}[ERRO] Nenhuma playlist válida encontrada em $CONFIG${RESET}"
  exit 1
fi

SORTED=$(sort -t'|' -k1 -n "$ANALISE" | head -100)

echo ""
separador
echo -e "${CYAN}${BOLD}   📋 ORDEM DE DOWNLOAD (Menor primeiro para entrega rápida)${RESET}"
separador
printf "  ${BOLD}%-3s %-38s %-18s %7s %10s${RESET}\n" "#" "Playlist / ID" "Artista" "Faixas" "Estimado"
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

  printf "  ${YELLOW}%3d${RESET} %-38s %-18s ${GREEN}%7d${RESET} %10s\n" "$ORDER" "$nome" "$artista" "$((10#$TAMANHO))" "$est"
done <<< "$SORTED"

if [[ "$TOTAL_EST_SEG" -gt 0 ]]; then
  if [[ "$TOTAL_EST_SEG" -ge 3600 ]]; then
    total_est=$(printf "%dh%02dm" $((TOTAL_EST_SEG / 3600)) $(( (TOTAL_EST_SEG % 3600) / 60 )))
  else
    total_est=$(printf "%dm%02ds" $((TOTAL_EST_SEG / 60)) $((TOTAL_EST_SEG % 60)))
  fi
  echo -e "\n  ${GREEN}⏱ Tempo estimado total de processamento: ${BOLD}${total_est}${RESET}"
fi

echo ""

# ============================================================
# FASE 2: BAIXANDO & SINCRONIZANDO PLAYLISTS
# ============================================================
separador
echo -e "${MAGENTA}${BOLD}   ⚡ FASE 2: BAIXANDO & SINCRONIZANDO AO VIVO COM O SERVIDOR${RESET}"
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
    echo "Playlist não encontrada ou deletada"
  else
    echo "Erro genérico no download"
  fi
}

while IFS='|' read -r TAMANHO ARTIST ALBUM GENRE URL; do
  ORDER=$((ORDER + 1))

  echo -e "${CYAN}------------------------------------------------------------------------------${RESET}"
  echo -e "${GREEN}${BOLD}  [${ORDER}/${TOTAL_PLAYLISTS}] ▶ ${ARTIST} — ${ALBUM}${RESET}"
  echo -e "${CYAN}------------------------------------------------------------------------------${RESET}"

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
    --sleep-requests 2.5
    --sleep-interval 1
    --max-sleep-interval 3
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

  echo -e "  ${CYAN}Etapa 1/2: Baixando áudios do YouTube...${RESET}"
  
  while true; do
    yt-dlp "${YT_ARGS[@]}" "$URL" 2>&1 | tee "$YT_LOG" | python3 "$SCRIPT_DIR/format_progress.py" || true
    
    if grep -q -i "rate-limited by YouTube" "$YT_LOG" || grep -q -i "HTTP Error 429" "$YT_LOG" || grep -q -i "Sign in to confirm you’re not a bot" "$YT_LOG"; then
      echo ""
      echo -e "${YELLOW}┌──────────────────────────────────────────────────────────────────────────┐${RESET}"
      echo -e "${YELLOW}│ ⏳ ${BOLD}PAUSA AUTOMÁTICA ATIVADA${RESET}${YELLOW} (Limite de requisições do YouTube)   │${RESET}"
      echo -e "${YELLOW}├──────────────────────────────────────────────────────────────────────────┤${RESET}"
      echo -e "${YELLOW}│ 🕒 Horário de Início: ${BOLD}$(date '+%H:%M:%S')${RESET}${YELLOW}                                  │${RESET}"
      echo -e "${YELLOW}│ 🚀 VPS Sincronização: ${GREEN}${BOLD}✔ Enviando faixas recentes ao servidor...${RESET}${YELLOW}  │${RESET}"
      
      python3 "$SCRIPT_DIR/flatten_library.py" "$MUSIC_ROOT" 2>/dev/null || true
      rsync -avz --update "$MUSIC_ROOT/" oracle24:/home/ubuntu/musica/ 2>/dev/null || true
      ssh -o StrictHostKeyChecking=no oracle24 "python3 /home/ubuntu/flatten_library.py /home/ubuntu/musica && sudo docker restart swingmusic" 2>/dev/null || true
      
      echo -e "${YELLOW}│ 💤 Descansando por 1 hora (3600s)...                                    │${RESET}"
      echo -e "${YELLOW}└──────────────────────────────────────────────────────────────────────────┘${RESET}"
      sleep 3600
      echo -e "\n${GREEN}  ✔ 1 hora concluída! Retomando downloads automaticamente...${RESET}\n"
      rm -f "$YT_LOG"
      YT_LOG=$(mktemp)
      continue
    fi
    break
  done

  HAS_MP3=$(find "$PLAYLIST_DIR" -maxdepth 1 -name "*.mp3" 2>/dev/null | wc -l)
  if [[ "$HAS_MP3" -eq 0 ]]; then
    if grep -q -i "has already been recorded in the archive" "$YT_LOG"; then
      rm -f "$YT_LOG"
      TOTAL_OK=$((TOTAL_OK + 1))
      echo -e "  ${GREEN}✔ [OK] Playlist já baixada anteriormente (registrada no histórico)${RESET}\n"
      continue
    fi
    MOTIVO=$(extrair_motivo_erro "$YT_LOG")
    rm -f "$YT_LOG"
    echo -e "\n  ${RED}✖ [ERRO CRÍTICO] Falha ao baixar playlist: ${ARTIST} - ${ALBUM}${RESET}"
    echo -e "  ${RED}  Motivo: $MOTIVO${RESET}\n"
    FAILED_URLS+=("$URL")
    FAILED_ARTISTS+=("$ARTIST")
    FAILED_ALBUMS+=("$ALBUM")
    FAILED_GENRES+=("$GENRE")
    FAILED_REASONS+=("$MOTIVO")
    TOTAL_FAIL=$((TOTAL_FAIL + 1))
    continue
  fi
  rm -f "$YT_LOG"

  echo -e "  ${CYAN}Etapa 2/2: Aplicando tags de áudio e organizando...${RESET}"
  python3 "$SCRIPT_DIR/tag_and_sort.py" \
    --input "$PLAYLIST_DIR" \
    --artist "$ARTIST" \
    --album "$ALBUM" \
    --genre "$GENRE" \
    --output "$MUSIC_ROOT" 2>&1 | sed 's/^/    /'
  TAGS_EXIT="${PIPESTATUS[0]:-1}"

  if [[ "$TAGS_EXIT" -ne 0 ]]; then
    MOTIVO="Falha ao organizar tags com tag_and_sort.py"
    echo -e "\n  ${RED}✖ [ERRO] $MOTIVO${RESET}\n"
    FAILED_URLS+=("$URL")
    FAILED_ARTISTS+=("$ARTIST")
    FAILED_ALBUMS+=("$ALBUM")
    FAILED_GENRES+=("$GENRE")
    FAILED_REASONS+=("$MOTIVO")
    TOTAL_FAIL=$((TOTAL_FAIL + 1))
    continue
  fi

  TOTAL_OK=$((TOTAL_OK + 1))
  echo -e "  ${GREEN}✔ [OK] Sucesso: ${ARTIST} - ${ALBUM}${RESET}\n"

done <<< "$SORTED"

# ============================================================
# FASE 3: RETENTATIVA DE FALHAS
# ============================================================
if [[ ${#FAILED_URLS[@]} -gt 0 ]]; then
  echo ""
  separador
  echo -e "${YELLOW}${BOLD}   🔄 FASE 3: RETENTATIVA AUTOMÁTICA DE PLAYLISTS COM ERRO${RESET}"
  separador
  echo ""

  STILL_FAILED_URLS=()
  STILL_FAILED_ARTISTS=()
  STILL_FAILED_ALBUMS=()
  STILL_FAILED_REASONS=()

  for i in "${!FAILED_URLS[@]}"; do
    URL="${FAILED_URLS[$i]}"
    ARTIST="${FAILED_ARTISTS[$i]}"
    ALBUM="${FAILED_ALBUMS[$i]}"
    GENRE="${FAILED_GENRES[$i]}"
    MOTIVO="${FAILED_REASONS[$i]}"

    echo -e "  ${YELLOW}Tentando novamente: ${ARTIST} - ${ALBUM}${RESET}"

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
      --sleep-requests 2.5
      --sleep-interval 1
      --max-sleep-interval 3
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

    while true; do
      yt-dlp "${YT_ARGS[@]}" "$URL" 2>&1 | tee "$YT_LOG" | python3 "$SCRIPT_DIR/format_progress.py" || true
      if grep -q -i "rate-limited by YouTube" "$YT_LOG" || grep -q -i "HTTP Error 429" "$YT_LOG" || grep -q -i "Sign in to confirm you’re not a bot" "$YT_LOG"; then
        echo -e "${YELLOW}  [PAUSA AUTOMÁTICA] Limite do YouTube atingido. Pausando por 1 hora (3600s)...${RESET}"
        
        python3 "$SCRIPT_DIR/flatten_library.py" "$MUSIC_ROOT" 2>/dev/null || true
        rsync -avz --update "$MUSIC_ROOT/" oracle24:/home/ubuntu/musica/ 2>/dev/null || true
        ssh -o StrictHostKeyChecking=no oracle24 "python3 /home/ubuntu/flatten_library.py /home/ubuntu/musica && sudo docker restart swingmusic" 2>/dev/null || true
        
        sleep 3600
        rm -f "$YT_LOG"
        YT_LOG=$(mktemp)
        continue
      fi
      break
    done

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
        echo -e "  ${GREEN}✔ [OK RETENTATIVA] Sucesso na retentativa!${RESET}"
      else
        MOTIVO="Falha ao aplicar tags na retentativa (Exit: $TAGS_EXIT)"
        TOTAL_FAIL=$((TOTAL_FAIL + 1))
        STILL_FAILED_URLS+=("$URL")
        STILL_FAILED_ARTISTS+=("$ARTIST")
        STILL_FAILED_ALBUMS+=("$ALBUM")
        STILL_FAILED_REASONS+=("$MOTIVO")
        echo -e "  ${RED}✖ [ERRO RETENTATIVA] $MOTIVO${RESET}"
      fi
    else
      MOTIVO=$(extrair_motivo_erro "$YT_LOG")
      TOTAL_FAIL=$((TOTAL_FAIL + 1))
      STILL_FAILED_URLS+=("$URL")
      STILL_FAILED_ARTISTS+=("$ARTIST")
      STILL_FAILED_ALBUMS+=("$ALBUM")
      STILL_FAILED_REASONS+=("$MOTIVO")
      echo -e "  ${RED}✖ [ERRO RETENTATIVA] $MOTIVO${RESET}"
    fi
    rm -f "$YT_LOG"
  done

  FAILED_URLS=("${STILL_FAILED_URLS[@]:-}")
  FAILED_ARTISTS=("${STILL_FAILED_ARTISTS[@]:-}")
  FAILED_ALBUMS=("${STILL_FAILED_ALBUMS[@]:-}")
  FAILED_REASONS=("${STILL_FAILED_REASONS[@]:-}")
fi

# Sincronizacao final com o servidor
if [[ -n "$SERVER_SYNC" ]]; then
  echo ""
  echo -e "${CYAN}  🚀 Executando sincronização final com o servidor VPS...${RESET}"
  python3 "$SCRIPT_DIR/flatten_library.py" "$MUSIC_ROOT" 2>/dev/null || true
  rsync -avz --update "$MUSIC_ROOT/" oracle24:/home/ubuntu/musica/ 2>/dev/null || true
  ssh -o StrictHostKeyChecking=no oracle24 "python3 /home/ubuntu/flatten_library.py /home/ubuntu/musica && sudo docker restart swingmusic" 2>/dev/null || true
fi

# ============================================================
# RELATORIO FINAL
# ============================================================
echo ""
separador
echo -e "${MAGENTA}${BOLD}   📊 PAINEL FINAL DE RESULTADOS & SINCRONIZAÇÃO${RESET}"
separador
echo ""
echo -e "  ${GREEN}✔ Playlists Baixadas com Sucesso:${RESET} ${BOLD}${TOTAL_OK}${RESET}"
echo -e "  ${RED}✖ Playlists com Falhas:${RESET}             ${BOLD}${TOTAL_FAIL}${RESET}"
echo -e "  ${CYAN}☁ Servidor VPS Target:${RESET}              ${BOLD}${SERVER_SYNC:-Local}${RESET}"
echo -e "  ${WHITE}📁 Pasta Local de Música:${RESET}           ${BOLD}${MUSIC_ROOT}${RESET}"
echo -e "  ${WHITE}📄 Arquivo de Log:${RESET}                   ${BOLD}${LOG_FILE}${RESET}"
echo ""

if [[ ${#FAILED_URLS[@]} -gt 0 ]]; then
  echo -e "${RED}  PLAYLISTS QUE NÃO PUDERAM SER BAIXADAS:${RESET}"
  for i in "${!FAILED_URLS[@]}"; do
    echo -e "    ${RED}• ${FAILED_ARTISTS[$i]} - ${FAILED_ALBUMS[$i]}${RESET}"
    echo -e "      ${DIM}URL:${RESET} ${FAILED_URLS[$i]}"
    echo -e "      ${RED}Motivo:${RESET} ${FAILED_REASONS[$i]}"
  done
  echo ""
fi

separador
echo -e "${GREEN}${BOLD}   ✨ PROCESSO CONCLUÍDO COM SUCESSO! APROVEITE SEU SWINGMUSIC! 🎶${RESET}"
separador
echo ""
