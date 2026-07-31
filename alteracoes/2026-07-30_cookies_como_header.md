# Cookies passados como header HTTP

**Data:** 2026-07-30

## O que mudou
- Substituiu `--cookies cookies.txt` por `--add-header "Cookie: <valor>"` no `download_music.sh`
- Removeu instalação automática do Deno (não mais necessária)
- `--extractor-args "youtube:player_client=android"` agora é usado sempre (com ou sem cookies)

## Motivo
O yt-dlp, quando recebe `--cookies`, pula automaticamente clients que não suportam cookies (android, ios, tv) e tenta usar web/web_music, que exigem PO Token e JS signature solving — ambos falham. Ao passar o cookie como header HTTP (`--add-header`), o yt-dlp não detecta que cookies foram fornecidos, não pula o client android, e o cookie ainda é enviado nas requisições para bypassar o bloqueio de bot do YouTube.

## Arquivos Impactados
- `download_music.sh` (cookie handling, remoção deno install)
