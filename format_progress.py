#!/usr/bin/env python3
"""
format_progress.py
Filtra os logs verbosos do yt-dlp e exibe uma interface limpa, sem rastros
de texto residual, separando claramente o que foi concluído do que está baixando.
"""
import sys
import re

BOLD = "\033[1m"
RESET = "\033[0m"
CYAN = "\033[1;36m"
GREEN = "\033[1;32m"
YELLOW = "\033[1;33m"
RED = "\033[1;31m"
CLEAR_LINE = "\033[K"

current_item = ""
total_items = ""
last_was_bar = False

def draw_progress_bar(percent_float, speed="", eta=""):
    global last_was_bar
    width = 25
    filled = int(width * (percent_float / 100.0))
    bar = "█" * filled + "░" * (width - filled)
    sp_str = f" | {speed}" if speed else ""
    eta_str = f" | ETA: {eta}" if eta else ""
    item_str = f"[{current_item}/{total_items}] " if current_item else ""
    sys.stdout.write(f"\r  {CYAN}↳ {item_str}{bar} {percent_float:.1f}%{sp_str}{eta_str}{RESET}{CLEAR_LINE}")
    sys.stdout.flush()
    last_was_bar = True

for line in sys.stdin:
    line_clean = line.strip()

    # Detecta item da playlist: [download] Downloading item 15 of 200
    item_match = re.search(r"Downloading item (\d+) of (\d+)", line_clean)
    if item_match:
        current_item = item_match.group(1)
        total_items = item_match.group(2)
        if last_was_bar:
            sys.stdout.write("\n")
            last_was_bar = False
        sys.stdout.write(f"  {YELLOW}⏬ [{current_item}/{total_items}]{RESET} Baixando faixa...{CLEAR_LINE}\n")
        sys.stdout.flush()
        continue

    # Detecta porcentagem de download
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

    # Detecta conclusao de faixa
    if "[MOVIDO PARA BIBLIOTECA]" in line_clean or "[OK]" in line_clean:
        txt = line_clean.replace("[MOVIDO PARA BIBLIOTECA]", "").strip()
        sys.stdout.write(f"\r  {GREEN}✔ [CONCLUÍDO] {txt}{RESET}{CLEAR_LINE}\n")
        sys.stdout.flush()
        last_was_bar = False
        continue

    # Detecta erro de bot/rate limit e formata limpo
    if "Sign in to confirm you’re not a bot" in line_clean or "rate-limited" in line_clean:
        sys.stdout.write(f"\r  {RED}✖ [BLOQUEIO YT] Sessão atingiu limite antispam do YouTube.{RESET}{CLEAR_LINE}\n")
        sys.stdout.flush()
        last_was_bar = False
        continue

    # Mensagens importantes do sistema
    if "PAUSA AUTOMÁTICA" in line_clean or "Retomando" in line_clean or "Sincronizando" in line_clean:
        if last_was_bar:
            sys.stdout.write("\n")
            last_was_bar = False
        sys.stdout.write(f"  {line_clean}{CLEAR_LINE}\n")
        sys.stdout.flush()
        continue

if last_was_bar:
    sys.stdout.write("\n")
