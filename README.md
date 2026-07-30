# ytmusic-downloader

Baixa playlists do YouTube (áudio + capa), organiza automaticamente em
`Gênero/Artista/Álbum` e deixa pronto pro Swing Music reconhecer.

Feito pra rodar **direto no servidor Oracle**, na mesma pasta onde o volume
de música do Swing Music (`/root/musica`) já existe — assim não precisa de
`scp` depois, os arquivos já nascem no lugar certo.

## 1. Instalar dependências (no servidor)

```bash
sudo apt update && sudo apt install -y ffmpeg python3-pip
pip install yt-dlp mutagen requests --break-system-packages
```

## 2. Copiar os arquivos pro servidor

Manda esses 3 arquivos (`download_music.sh`, `tag_and_sort.py`,
`playlists.example.txt`) pra uma pasta no servidor, ex: `~/ytmusic-downloader`.

```bash
chmod +x download_music.sh
cp playlists.example.txt playlists.txt
```

## 3. (Opcional, mas necessário pra playlists privadas/Liked Videos) Cookies

Pra baixar playlists privadas ou "Liked Videos", o yt-dlp precisa dos
cookies da sua conta logada:

1. Instala a extensão **"Get cookies.txt LOCALLY"** no Chrome.
2. Loga no YouTube normalmente.
3. Exporta os cookies do site youtube.com como `cookies.txt`.
4. Manda esse arquivo pro servidor, na mesma pasta do script.

Sem isso, só playlists **públicas** vão funcionar.

## 4. Editar a lista de playlists

Abre `playlists.txt` e edita:

```
https://www.youtube.com/playlist?list=XXXXX|Charlie Brown Jr|Coletânea Charlie Brown Jr|Rock Nacional
```

- Todas as faixas dessa URL caem juntas num álbum só (`Coletânea Charlie Brown Jr`), exatamente pro caso que você mencionou.
- `Genero` pode ser `auto` (tenta descobrir automaticamente via MusicBrainz, com base no nome do artista) ou um valor fixo tipo `MPB`, `Rock Nacional`, `Eletrônica` etc.

## 5. Rodar

```bash
MUSIC_ROOT=/root/musica ./download_music.sh playlists.txt
```

Isso vai:
1. Baixar cada playlist como MP3 (melhor qualidade de áudio), com a
   thumbnail do vídeo embutida como capa.
2. Forçar as tags de Artista/Álbum/Gênero/Faixa (ignorando o título
   bagunçado que às vezes vem do YouTube).
3. Mover tudo pra `/root/musica/Genero/Artista/Album/NN - Faixa.mp3`.
4. Reiniciar o container `swingmusic` automaticamente pra ele reconhecer
   as faixas novas (se não achar o container, só te avisa pra reiniciar
   manualmente).

## Sobre a detecção automática de gênero

Não existe "gênero" nativo em vídeo do YouTube — o script busca o artista
no **MusicBrainz** (banco de dados aberto de música) e pega a tag/gênero
mais associada a ele. Funciona bem pra artistas conhecidos; artistas muito
nichados ou nomes ambíguos podem cair em "Outros". Nesse caso, é só
sobrescrever manualmente no `playlists.txt` com um gênero fixo.

## Sobre o Spotify

Esse script cobre só YouTube. Pro Spotify, o fluxo é parecido mas usa o
`spotdl` (que puxa metadados oficiais do Spotify e baixa o áudio
correspondente via YouTube) — te aviso que é um projeto separado, com
autenticação OAuth própria. Se quiser, posso montar um script equivalente
pra ele depois.

## Rodando de novo / atualizando

O script é seguro de rodar múltiplas vezes — `--no-overwrites` no yt-dlp
evita baixar de novo o que já foi puxado na mesma execução. Se quiser
adicionar playlists novas, só acrescenta linhas no `playlists.txt` e roda
de novo; os álbuns antigos não são mexidos.
# MusicSwing
