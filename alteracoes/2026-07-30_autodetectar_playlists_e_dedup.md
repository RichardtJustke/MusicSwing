# Alteracao: Autodetectar playlists e deduplicacao

**Data:** 2026-07-30

**O que foi alterado:**
- Adicionada deteccao automatica de artista/album via `yt-dlp --flat-playlist --dump-json` quando a linha nao contem `|`
- Adicionada deduplicacao de URLs iguais no mesmo arquivo (via `declare -A SEEN_URLS`)
- Linhas que nao comecam com `https?://` sao ignoradas (permite notas soltas no arquivo)
- `playlists.txt` limpo: URLs unicas, sem parametros `&si=` e sem duplicatas

**Motivo:**
Usuario colou URLs puras do YouTube Music sem o formato `URL|Artista|Album|Genero`. Agora o script autodetects essas informacoes, permitindo que o usuario so cole as URLs e rode.

**Arquivos impactados:**
- `download_music.sh`
- `playlists.txt`
