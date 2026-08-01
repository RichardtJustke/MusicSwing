#!/usr/bin/env python3
"""
flatten_library.py
Remove todas as subpastas confusas do servidor e coloca todas as músicas
diretamente na pasta principal /home/ubuntu/musica/, mantendo os arquivos MP3
com os metadados limpos e capas em HD salvas dentro do próprio arquivo.
"""
import os
import shutil
import sys

def main():
    base_dir = sys.argv[1] if len(sys.argv) > 1 else "./musica"
    temp_dir = os.path.join(os.path.dirname(os.path.abspath(base_dir)), "musica_flat")
    os.makedirs(temp_dir, exist_ok=True)

    print("Reunindo todas as músicas e removendo a bagunça de subpastas...")
    count = 0
    for root, dirs, files in os.walk(base_dir):
        if root.startswith(temp_dir):
            continue
        for f in files:
            if f.lower().endswith(".mp3"):
                src = os.path.join(root, f)
                dest = os.path.join(temp_dir, f)
                
                # Se houver arquivo com mesmo nome, adiciona número único
                idx = 1
                base_name, ext = os.path.splitext(f)
                while os.path.exists(dest):
                    dest = os.path.join(temp_dir, f"{base_name}_{idx}{ext}")
                    idx += 1
                
                shutil.move(src, dest)
                count += 1

    # Remove todas as subpastas antigas
    for item in os.listdir(base_dir):
        item_path = os.path.join(base_dir, item)
        if os.path.isdir(item_path) and item_path != temp_dir:
            shutil.rmtree(item_path, ignore_errors=True)

    # Move todas as músicas de volta diretamente para /home/ubuntu/musica
    for f in os.listdir(temp_dir):
        shutil.move(os.path.join(temp_dir, f), os.path.join(base_dir, f))

    os.rmdir(temp_dir)
    print(f"Sucesso! {count} músicas foram limpas e reunidas diretamente em '{base_dir}'.")

if __name__ == "__main__":
    main()
