#!/usr/bin/env bash
#
# download_music.sh
#
# Baixa playlists do YouTube (áudio + thumbnail como capa), força
# artista/álbum/gênero por playlist e organiza tudo em:
#     $MUSIC_ROOT/Genero/Artista/Album/NN - Titulo.mp3
#
# Rode direto NO SERVIDOR ORACLE (dentro da pasta onde o Swing Music
# tem o volume /root/musica montado), assim não precisa de scp depois.
#
# Uso:
#   ./download_music.sh [arquivo_de_playlists.txt]
#
# Formato do arquivo de playlists (uma por linha, separado por "|"):
#   URL|Artista|Album|Genero
#
# Genero pode ser "auto" (tenta descobrir via MusicBrainz) ou um valor fixo.
# Linhas começando com # são ignoradas.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${1:-$SCRIPT_DIR/playlists.txt}"
MUSIC_ROOT="${MUSIC_ROOT:-/root/musica}"
COOKIES="${COOKIES:-$SCRIPT_DIR/cookies.txt}"
ARCHIVES_DIR="$SCRIPT_DIR/archives"
mkdir -p "$ARCHIVES_DIR"

if [[ ! -f "$CONFIG" ]]; then
  echo "Arquivo de playlists não encontrado: $CONFIG"
  echo "Copia o playlists.example.txt pra playlists.txt e edita com suas playlists."
  exit 1
fi

command -v yt-dlp >/dev/null || { echo "yt-dlp não instalado. Roda: pip install yt-dlp --break-system-packages"; exit 1; }
command -v python3 >/dev/null || { echo "python3 não encontrado."; exit 1; }
python3 -c "import mutagen" 2>/dev/null || { echo "Falta mutagen. Roda: pip install mutagen requests --break-system-packages"; exit 1; }

STAGING="$(mktemp -d)"
trap 'rm -rf "$STAGING"' EXIT

TOTAL=0
declare -A SEEN_URLS

while IFS='|' read -r URL ARTIST ALBUM GENRE || [ -n "${URL:-}" ]; do
  URL="$(echo "$URL" | xargs)"
  [[ -z "$URL" ]] && continue
  [[ "$URL" =~ ^# ]] && continue
  [[ ! "$URL" =~ ^https?:// ]] && continue

  if [[ -n "${SEEN_URLS[$URL]:-}" ]]; then
    echo "==> Pulando URL duplicada: $URL"
    continue
  fi
  SEEN_URLS[$URL]=1

  if [[ -z "${ARTIST// }" ]]; then
    echo "==> Detectando playlist automaticamente..."
    INFO=$(yt-dlp --flat-playlist --dump-json "$URL" 2>/dev/null | head -1)
    if [ -n "$INFO" ]; then
      ARTIST=$(echo "$INFO" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('channel') or d.get('uploader') or 'Desconhecido')
")
      ALBUM=$(echo "$INFO" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('playlist_title') or d.get('title') or 'Playlist')
")
    else
      ARTIST="Desconhecido"
      ALBUM="Playlist"
    fi
    GENRE="auto"
    echo "    Artista: $ARTIST | Album: $ALBUM"
  fi

  ARTIST="$(echo "$ARTIST" | xargs)"
  ALBUM="$(echo "$ALBUM" | xargs)"
  GENRE="$(echo "${GENRE:-auto}" | xargs)"

  echo ""
  echo "==> Baixando playlist: $ARTIST - $ALBUM"
  echo "    URL: $URL"

  SAFE_NAME="$(echo "${ARTIST}_${ALBUM}" | tr ' /' '__')"
  PLAYLIST_DIR="$STAGING/$SAFE_NAME"
  mkdir -p "$PLAYLIST_DIR"

  YT_ARGS=(
    -x --audio-format mp3 --audio-quality 0
    --embed-thumbnail
    --no-embed-metadata
    --ignore-errors
    --no-overwrites
    --download-archive "$ARCHIVES_DIR/${SAFE_NAME}.txt"
    -o "$PLAYLIST_DIR/%(playlist_index)03d - %(title)s.%(ext)s"
  )

  if [[ -f "$COOKIES" ]]; then
    YT_ARGS+=(--cookies "$COOKIES")
  else
    echo "    [aviso] cookies.txt não encontrado — só vai funcionar para playlists públicas."
  fi

  yt-dlp "${YT_ARGS[@]}" "$URL" || echo "    [aviso] alguns vídeos podem ter falhado, seguindo em frente."

  python3 "$SCRIPT_DIR/tag_and_sort.py" \
    --input "$PLAYLIST_DIR" \
    --artist "$ARTIST" \
    --album "$ALBUM" \
    --genre "$GENRE" \
    --output "$MUSIC_ROOT"

  TOTAL=$((TOTAL + 1))
done < "$CONFIG"

echo ""
echo "==> $TOTAL playlist(s) processada(s). Biblioteca em: $MUSIC_ROOT"

if command -v docker >/dev/null && docker ps --format '{{.Names}}' | grep -q '^swingmusic$'; then
  echo "==> Reiniciando o container swingmusic pra reconhecer as novas faixas..."
  docker restart swingmusic
else
  echo "==> Não achei o container 'swingmusic' rodando. Reinicia manualmente se precisar:"
  echo "    docker compose restart"
fi

echo "Pronto!"
