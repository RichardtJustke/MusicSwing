#!/usr/bin/env python3
"""
tag_and_sort.py

Pega os MP3s baixados de uma playlist (numa pasta temporária), força as tags
de Artista/Álbum/Gênero (sobrescrevendo o que veio do YouTube), tenta
descobrir o gênero musical automaticamente via MusicBrainz quando não
informado, e move tudo pra estrutura final:

    <output>/<Genero>/<Artista>/<Album>/NN - Titulo.mp3

Uso (chamado pelo download_music.sh, mas pode rodar isolado):
    python3 tag_and_sort.py --input /tmp/staging/playlist1 \
        --artist "Charlie Brown Jr" --album "Coletânea" \
        --genre auto --output /root/musica
"""

import argparse
import os
import re
import shutil
import sys
import time
import unicodedata

try:
    from mutagen.easyid3 import EasyID3
    from mutagen.mp3 import MP3
    from mutagen.id3 import ID3NoHeaderError
except ImportError:
    sys.exit("Falta instalar o mutagen: pip install mutagen --break-system-packages")

try:
    import requests
except ImportError:
    requests = None  # só é necessário se for usar --genre auto

MUSICBRAINZ_UA = "ytmusic-downloader/1.0 (personal self-hosted use)"
GENRE_CACHE = {}


def sanitize(name: str) -> str:
    """Remove caracteres problemáticos pra nome de pasta/arquivo."""
    name = unicodedata.normalize("NFC", name)
    name = re.sub(r'[\\/:*?"<>|]', "", name)
    name = name.strip().strip(".")
    return name or "Desconhecido"


def lookup_genre_musicbrainz(artist: str) -> str:
    """Tenta descobrir o gênero mais comum de um artista via MusicBrainz.
    Cai pra 'Outros' se não achar nada ou se o requests não estiver disponível."""
    fallback = "Outros"
    if not artist or artist.strip().lower() in ("desconhecido", "unknown", "vários artistas", "various artists", "va", "auto"):
        GENRE_CACHE[artist] = fallback
        return fallback

    if artist in GENRE_CACHE:
        return GENRE_CACHE[artist]

    if requests is None:
        return fallback

    try:
        resp = requests.get(
            "https://musicbrainz.org/ws/2/artist/",
            params={"query": f'artist:"{artist}"', "fmt": "json", "limit": 1},
            headers={"User-Agent": MUSICBRAINZ_UA},
            timeout=10,
        )
        resp.raise_for_status()
        artists = resp.json().get("artists", [])
        if not artists:
            GENRE_CACHE[artist] = fallback
            return fallback

        mbid = artists[0]["id"]
        # respeita rate limit do MusicBrainz (1 req/s)
        time.sleep(1)

        resp2 = requests.get(
            f"https://musicbrainz.org/ws/2/artist/{mbid}",
            params={"inc": "genres+tags", "fmt": "json"},
            headers={"User-Agent": MUSICBRAINZ_UA},
            timeout=10,
        )
        resp2.raise_for_status()
        data = resp2.json()

        genres = data.get("genres") or data.get("tags") or []
        if genres:
            genres.sort(key=lambda g: g.get("count", 0), reverse=True)
            genre = genres[0]["name"].title()
            GENRE_CACHE[artist] = genre
            return genre
    except Exception as e:
        print(f"    [aviso] não consegui buscar gênero pra '{artist}': {e}")

    GENRE_CACHE[artist] = fallback
    return fallback


def strip_track_prefix(filename: str) -> str:
    """Remove o prefixo '001 - ' que o yt-dlp adiciona, deixando só o título."""
    stem = os.path.splitext(filename)[0]
    return re.sub(r"^\d+\s*-\s*", "", stem).strip()


def extract_track_number(filename: str) -> str:
    m = re.match(r"^(\d+)\s*-", filename)
    return m.group(1) if m else "1"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--input", help="pasta ou arquivo mp3 baixado")
    ap.add_argument("--file", help="arquivo mp3 individual")
    ap.add_argument("--artist", required=True)
    ap.add_argument("--album", required=True)
    ap.add_argument("--genre", default="auto", help="'auto' pra tentar descobrir, ou um valor fixo")
    ap.add_argument("--output", required=True, help="raiz da biblioteca de música final")
    args = ap.parse_args()

    target_input = args.file or args.input
    if not target_input:
        sys.exit("É necessário especificar --file ou --input")

    genre = args.genre.strip()
    if not genre or genre.lower() == "auto":
        genre = lookup_genre_musicbrainz(args.artist)
        print(f"    Gênero detectado para '{args.artist}': {genre}")

    artist_dir = sanitize(args.artist)
    album_dir = sanitize(args.album)
    genre_dir = sanitize(genre)

    dest_dir = os.path.join(args.output, genre_dir, artist_dir, album_dir)
    os.makedirs(dest_dir, exist_ok=True)

    if os.path.isfile(target_input):
        files_to_process = [target_input]
    elif os.path.isdir(target_input):
        files_to_process = sorted(
            os.path.join(target_input, f) for f in os.listdir(target_input) if f.lower().endswith(".mp3")
        )
    else:
        print(f"    [aviso] caminho não encontrado: {target_input}")
        return

    if not files_to_process:
        print(f"    [aviso] nenhum mp3 encontrado em {target_input}")
        return

    for src in files_to_process:
        fname = os.path.basename(src)
        track_num = extract_track_number(fname)
        title = strip_track_prefix(fname)

        try:
            audio = EasyID3(src)
        except ID3NoHeaderError:
            audio = MP3(src, easy=True)
            audio.add_tags()

        # Preserva o artista original extraído pelo yt-dlp do YouTube caso args.artist seja "Desconhecido"
        existing_artist = audio.get("artist", [""])[0] if audio.get("artist") else ""
        final_artist = existing_artist.strip() if (args.artist.lower() in ("desconhecido", "unknown", "") and existing_artist and existing_artist.strip()) else args.artist

        # Preserva o álbum original extraído pelo yt-dlp do YouTube caso args.album seja um ID (ex: OLAK... ou PL...)
        existing_album = audio.get("album", [""])[0] if audio.get("album") else ""
        is_album_id = bool(re.match(r"^(PL|OLAK|UC)[A-Za-z0-9_-]+$", args.album))
        final_album = existing_album.strip() if (is_album_id and existing_album and existing_album.strip()) else args.album

        audio["artist"] = final_artist
        audio["albumartist"] = final_artist
        if final_album:
            audio["album"] = final_album
        audio["title"] = title
        audio["genre"] = genre
        audio["tracknumber"] = track_num
        audio.save()

        artist_dir = sanitize(final_artist)
        album_dir = sanitize(final_album or "Álbum")
        dest_dir = os.path.join(args.output, genre_dir, artist_dir, album_dir)
        os.makedirs(dest_dir, exist_ok=True)

        dest_name = f"{int(track_num):02d} - {sanitize(title)}.mp3"
        dest_path = os.path.join(dest_dir, dest_name)
        if os.path.exists(dest_path):
            print(f"    [pulado] já existe: {dest_name}")
            if os.path.exists(src) and src != dest_path:
                try:
                    os.remove(src)
                except OSError:
                    pass
            continue
        shutil.move(src, dest_path)
        print(f"    [MOVIDO PARA BIBLIOTECA] {dest_name}")

        server_sync = os.environ.get("SERVER_SYNC")
        if server_sync:
            try:
                rel_path = os.path.relpath(dest_path, args.output)
                key_path = os.path.expanduser("~/Downloads/oracle-24gb.key")
                ssh_key_opt = f"-i '{key_path}' " if os.path.exists(key_path) else ""
                sync_cmd = f"rsync -avzR -e 'ssh {ssh_key_opt}-o StrictHostKeyChecking=no' './{rel_path}' '{server_sync}'"
                res = os.system(f"cd '{args.output}' && {sync_cmd}")
                if res == 0:
                    print(f"    [ENVIADO PARA SERVIDOR] -> {server_sync}/{rel_path}")
                else:
                    print(f"    [AVISO] rsync retornou codigo {res} ao enviar {dest_name}")
            except Exception as se:
                print(f"    [AVISO] Falha ao enviar para servidor: {se}")

    if os.path.isdir(target_input):
        print(f"    -> {len(files_to_process)} faixa(s) organizada(s) em {dest_dir}")


if __name__ == "__main__":
    main()
