# Remote Components EJS para resolver JS challenges

**Data:** 2026-07-30

## O que mudou
- Substituiu `--add-header "Cookie: <valor>"` + `--extractor-args "youtube:player_client=android"` por `--cookies cookies.txt` + `--remote-components ejs:github`
- Adicionou instalação automática do Deno (necessário para executar os scripts JS de resolução de desafios)
- Removeu o hack de passar cookie como header HTTP

## Motivo
O client android + cookies como header funcionava em IPs residenciais mas falhava no servidor Oracle (datacenter IP bloqueado pelo YouTube). Com `--remote-components ejs:github`, o yt-dlp baixa scripts JS de resolução de desafios do repositório oficial, que executados via Deno resolvem as assinaturas necessárias para o client web/web_music. Combinado com `--cookies`, o fluxo completo funciona também em datacenters.

## Arquivos Impactados
- `download_music.sh` (YT_ARGS, deno install, cookie handling)
