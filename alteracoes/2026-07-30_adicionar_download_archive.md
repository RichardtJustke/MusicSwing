# Alteracao: Adicionar controle de duplicatas via download-archive

**Data:** 2026-07-30

**O que foi alterado:**
- Adicionado `--download-archive` por playlist no `download_music.sh`, criando arquivos individuais em `archives/` para rastrear vídeos já baixados pelo ID do YouTube
- Adicionada verificação no `tag_and_sort.py` para pular arquivos que já existem no destino final
- Criado `playlists.txt` (template limpo para o usuário preencher)

**Motivo:**
Evitar que execuções repetidas do script acumulem arquivos duplicados no servidor. O `--download-archive` impede o re-download de vídeos já baixados (por ID do YouTube), e a verificação no Python impede sobrescrita/salvamento duplicado no diretório final.

**Arquivos impactados:**
- `download_music.sh`
- `tag_and_sort.py`
- `playlists.txt` (criado)
- `alteracoes/2026-07-30_adicionar_download_archive.md` (criado)
