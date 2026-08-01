# Estimativa de tempo e detecção de tamanho

**Data:** 2026-07-30

## O que mudou
- Adicionada detecção automática do número de faixas por playlist via `yt-dlp --flat-playlist --dump-json | wc -l`
- Adicionada coluna "Estimado" na tabela de ordem de download (cálculo: ~5s/faixa)
- Mostra tempo total estimado ao final da Fase 1
- Substituiu `set -euo pipefail` por `set -u` apenas (evita que exit code do yt-dlp com `--ignore-errors` mate o script)
- Download não verifica mais exit code do yt-dlp; verifica se `.mp3` foram gerados no diretório staging
- Retentativa também usa verificação por arquivos MP3 em vez de exit code

## Motivo
O yt-dlp retorna código 1 com `--ignore-errors` quando alguns vídeos da playlist estão indisponíveis, mas continua baixando os demais. O script antigo tratava isso como falha total, impedindo o `tag_and_sort.py` de rodar. Agora o script ignora o exit code e verifica se arquivos MP3 foram gerados.

## Arquivos Impactados
- `download_music.sh`
