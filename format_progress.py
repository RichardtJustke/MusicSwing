#!/usr/bin/env python3
"""
format_progress.py
Filtra os logs verbosos e poluídos do yt-dlp e exibe apenas uma barra de
progresso limpa e bonita no terminal, mostrando o essencial para o usuário.
"""
import sys
import re

BOLD = "\033[1m"
RESET = "\033[0m"
CYAN = "\033[1;36m"
GREEN = "\033[1;32m"
YELLOW = "\033[1;33m"
DIM = "\033[2m"

current_item = ""
total_items = ""

def draw_progress_bar(percent_float, speed="", eta=""):
    width = 25
    filled = int(width * (percent_float / 100.0))
    bar = "█" * filled + "░" * (width - filled)
    sp_str = f" | {speed}" if speed else ""
    eta_str = f" | ETA: {eta}" if eta else ""
    item_str = f"[{current_item}/{total_items}] " if current_item else ""
    sys.stdout.write(f"\r  {CYAN}↳ {item_str}{bar} {percent_float:.1f}%{sp_str}{eta_str}{RESET}   ")
    sys.stdout.flush()

for line in sys.stdin:
    line_clean = line.strip()

    # Detecta progresso de item na playlist: [download] Downloading item 15 of 200
    item_match = re.search(r"Downloading item (\d+) of (\d+)", line_clean)
    if item_match:
        current_item = item_match.group(1)
        total_items = item_match.group(2)
        sys.stdout.write(f"\n  {YELLOW}▶ [{current_item}/{total_items}]{RESET} Baixando faixa...\n")
        sys.stdout.flush()
        continue

    # Detecta porcentagem de download: [download]  45.2% of  3.20MiB at  4.50MiB/s ETA 00:02
    prog_match = re.search(r"\[download\]\s+(\d+\.\d+)%\s+of\s+~\s*(\S+)\s+at\s+(\S+)\s+ETA\s+(\S+)", line_clean) or \
                 re.search(r"\[download\]\s+(\d+\.\d+)%\s+of\s+(\S+)\s+at\s+(\S+)\s+ETA\s+(\S+)", line_clean)
    if prog_match:
        try:
            pct = float(prog_match.group(1))
            speed = prog_match.group(3)
            eta = prog_match.group(4)
            draw_progress_bar(pct, speed, eta)
        except ValueError:
            pass
        continue

    # Mostra confirmações limpas do tag_and_sort
    if "[MOVIDO PARA BIBLIOTECA]" in line_clean or "[OK]" in line_clean:
        txt = line_clean.replace("[MOVIDO PARA BIBLIOTECA]", "").strip()
        sys.stdout.write(f"\r  {GREEN}✔ {txt}{RESET}\n")
        sys.stdout.flush()
        continue

    # Repassa avisos de erro importantes ou de pausa
    if "PAUSA AUTOMÁTICA" in line_clean or "ERRO" in line_clean or "Retomando" in line_clean or "Sincronizando" in line_clean:
        sys.stdout.write(f"\n  {line_clean}\n")
        sys.stdout.flush()
        continue

sys.stdout.write("\n")
