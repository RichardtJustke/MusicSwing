#!/usr/bin/env python3
"""
server_enrich_metadata.py
Roda diretamente na VPS para buscar metadados oficiais (Artista, Álbum e Capa em HD)
na API do iTunes para faixas categorizadas como 'Vários Artistas' ou 'Desconhecido'.
"""
import os
import re
import shutil
import sys
import urllib.parse
import urllib.request
import json
import unicodedata

try:
    import mutagen
    from mutagen.easyid3 import EasyID3
    from mutagen.id3 import ID3, APIC
    from mutagen.mp3 import MP3
except ImportError:
    os.system("pip3 install mutagen requests")
    from mutagen.easyid3 import EasyID3
    from mutagen.id3 import ID3, APIC
    from mutagen.mp3 import MP3


def sanitize(name: str) -> str:
    if not name:
        return "Desconhecido"
    name = unicodedata.normalize("NFC", name)
    name = re.sub(r'[\\/:*?"<>|]', "", name)
    name = name.strip().strip(".")
    return name or "Desconhecido"


def clean_title_query(raw_title: str) -> str:
    title = re.sub(r"^\d+\s*[-_.]?\s*", "", raw_title)
    title = re.sub(r"\(official video.*?\)", "", title, flags=re.IGNORECASE)
    title = re.sub(r"\(video oficial.*?\)", "", title, flags=re.IGNORECASE)
    title = re.sub(r"\(clipe oficial.*?\)", "", title, flags=re.IGNORECASE)
    title = re.sub(r"\(audio.*?\)", "", title, flags=re.IGNORECASE)
    title = re.sub(r"\(lyric video.*?\)", "", title, flags=re.IGNORECASE)
    title = re.sub(r"\[.*?\]", "", title)
    title = re.sub(r"\(feat\..*?\)", "", title, flags=re.IGNORECASE)
    return title.strip()


def query_itunes(query: str):
    try:
        url = f"https://itunes.apple.com/search?term={urllib.parse.quote(query)}&entity=song&limit=1"
        req = urllib.request.Request(url, headers={"User-Agent": "Mozilla/5.0"})
        with urllib.request.urlopen(req, timeout=5) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            if data.get("resultCount", 0) > 0:
                return data["results"][0]
    except Exception:
        pass
    return None


def download_image(img_url: str):
    try:
        req = urllib.request.Request(img_url, headers={"User-Agent": "Mozilla/5.0"})
        with urllib.request.urlopen(req, timeout=5) as resp:
            return resp.read()
    except Exception:
        return None


def enrich_file(filepath, base_dir):
    filename = os.path.basename(filepath)
    raw_title = os.path.splitext(filename)[0]
    cleaned = clean_title_query(raw_title)

    try:
        audio_easy = EasyID3(filepath)
        curr_artist = audio_easy.get("artist", [""])[0]
    except Exception:
        curr_artist = ""

    # Só consulta iTunes se o artista atual for genérico
    if curr_artist.lower() in ("vários artistas", "varios artistas", "desconhecido", "unknown", ""):
        match = query_itunes(cleaned)
        if match:
            artist = match.get("artistName", "").strip()
            album = match.get("collectionName", "").strip()
            title = match.get("trackName", "").strip()
            artwork_url = match.get("artworkUrl100", "").replace("100x100bb", "1000x1000bb")

            if artist and title:
                print(f"[ITUNES MATCH] {cleaned} -> {artist} - {title} ({album})")
                
                # Salva metadados EasyID3
                audio_easy["artist"] = artist
                audio_easy["albumartist"] = artist
                audio_easy["album"] = album or title
                audio_easy["title"] = title
                audio_easy.save()

                # Baixa e insere Capa HD no MP3
                if artwork_url:
                    img_data = download_image(artwork_url)
                    if img_data:
                        try:
                            id3 = ID3(filepath)
                            id3.add(
                                APIC(
                                    encoding=3,
                                    mime="image/jpeg",
                                    type=3,
                                    desc="Cover",
                                    data=img_data
                                )
                            )
                            id3.save(v2_version=3)
                        except Exception:
                            pass

                # Move para a estrutura organizada no servidor
                genre = audio_easy.get("genre", ["Outros"])[0]
                dest_dir = os.path.join(base_dir, sanitize(genre), sanitize(artist), sanitize(album or title))
                os.makedirs(dest_dir, exist_ok=True)
                dest_path = os.path.join(dest_dir, filename)

                if filepath != dest_path:
                    if os.path.exists(dest_path):
                        os.remove(filepath)
                    else:
                        shutil.move(filepath, dest_path)
                    print(f"  -> Movido para: {dest_path}")


def main():
    base_dir = sys.argv[1] if len(sys.argv) > 1 else "/home/ubuntu/musica"
    print(f"Iniciando busca inteligente de metadados no servidor em '{base_dir}'...")

    total_checked = 0
    for root, _, files in os.walk(base_dir):
        for f in files:
            if f.lower().endswith(".mp3"):
                total_checked += 1
                enrich_file(os.path.join(root, f), base_dir)

    print(f"Varredura concluída! Verificados {total_checked} arquivos.")

    # Limpa pastas vazias
    for root, dirs, _ in os.walk(base_dir, topdown=False):
        for d in dirs:
            dp = os.path.join(root, d)
            if not os.listdir(dp):
                try:
                    os.rmdir(dp)
                except OSError:
                    pass


if __name__ == "__main__":
    main()
