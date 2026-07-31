#!/usr/bin/env python3
"""
fix_existing_metadata.py
Corrige as faixas já baixadas que ficaram marcadas como "Desconhecido",
restaurando os artistas e álbuns reais das tags ID3 e movendo para:
<output>/<Gênero>/<Artista Real>/<Álbum Real>/NN - Título.mp3
"""
import os
import re
import shutil
import sys
import unicodedata

try:
    from mutagen.easyid3 import EasyID3
    from mutagen.mp3 import MP3
except ImportError:
    sys.exit("Falta mutagen: pip install mutagen")


def sanitize(name: str) -> str:
    name = unicodedata.normalize("NFC", name)
    name = re.sub(r'[\\/:*?"<>|]', "", name)
    name = name.strip().strip(".")
    return name or "Desconhecido"


def fix_file(filepath, base_dir):
    try:
        audio = EasyID3(filepath)
    except Exception:
        return

    artist = audio.get("artist", [""])[0]
    title = audio.get("title", [""])[0] or os.path.splitext(os.path.basename(filepath))[0]
    album = audio.get("album", [""])[0]
    genre = audio.get("genre", ["Outros"])[0]

    # Se o artista era Desconhecido mas no título tem algo como "Artist - Title" ou "(feat. Artist)"
    feat_match = re.search(r"\(feat\.\s*([^)]+)\)", title, re.IGNORECASE)
    
    if artist.strip().lower() in ("desconhecido", "unknown", ""):
        if feat_match:
            artist = feat_match.group(1).strip()
        elif " - " in title:
            parts = title.split(" - ", 1)
            artist = parts[0].strip()
            title = parts[1].strip()

    if not artist or artist.strip().lower() in ("desconhecido", "unknown"):
        artist = "Vários Artistas"

    if not album or re.match(r"^(PL|OLAK|UC)[A-Za-z0-9_-]+$", album):
        album = "Singles & Coletâneas"

    audio["artist"] = artist
    audio["albumartist"] = artist
    audio["album"] = album
    audio.save()

    genre_dir = sanitize(genre)
    artist_dir = sanitize(artist)
    album_dir = sanitize(album)

    dest_dir = os.path.join(base_dir, genre_dir, artist_dir, album_dir)
    os.makedirs(dest_dir, exist_ok=True)

    dest_path = os.path.join(dest_dir, os.path.basename(filepath))
    if filepath != dest_path:
        if os.path.exists(dest_path):
            os.remove(filepath)
        else:
            shutil.move(filepath, dest_path)
            print(f"  [CORRIGIDO] {artist} - {title} -> {dest_path}")


def main():
    base_dir = sys.argv[1] if len(sys.argv) > 1 else "./musica"
    if not os.path.exists(base_dir):
        print(f"Diretório não encontrado: {base_dir}")
        return

    print(f"Organizando e corrigindo metadados em '{base_dir}'...")
    for root, _, files in os.walk(base_dir):
        for f in files:
            if f.lower().endswith(".mp3"):
                fix_file(os.path.join(root, f), base_dir)

    # Limpa pastas vazias
    for root, dirs, _ in os.walk(base_dir, topdown=False):
        for d in dirs:
            dp = os.path.join(root, d)
            if not os.listdir(dp):
                try:
                    os.rmdir(dp)
                except OSError:
                    pass

    print("Concluído!")


if __name__ == "__main__":
    main()
