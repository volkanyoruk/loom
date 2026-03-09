#!/bin/bash
# panel.sh — Multi-Agent Pipeline tmux paneli
# 6 bolmeli: Ece/Ceylin loglari + Ekip kanallari + Pipeline durumu

AGENTS="$(cd "$(dirname "$0")" && pwd)"
SESSION="agent-v2"

if tmux has-session -t "$SESSION" 2>/dev/null; then
    echo "Panel zaten calisiyor, baglaniliyor..."
    tmux attach -t "$SESSION"
    exit 0
fi

tmux new-session -d -s "$SESSION"

# === Pencere 1: Orkestrasyon (Ece + Ceylin + Durum) ===

# Pane 0 (sol ust) — ECE logu
tmux send-keys -t "$SESSION:0.0" \
    "printf '\033[34m━━━ ECE (Bas Mimar) ━━━\033[0m\n'; tail -f '$AGENTS/logs/ece.log' 2>/dev/null || (echo 'Bekleniyor...'; while ! [ -f '$AGENTS/logs/ece.log' ]; do sleep 2; done; tail -f '$AGENTS/logs/ece.log')" C-m

# Pane 1 (sag ust) — CEYLiN logu
tmux split-window -h -t "$SESSION:0.0"
tmux send-keys -t "$SESSION:0.1" \
    "printf '\033[36m━━━ CEYLiN (Orkestrator) ━━━\033[0m\n'; tail -f '$AGENTS/logs/ceylin.log' 2>/dev/null || (echo 'Bekleniyor...'; while ! [ -f '$AGENTS/logs/ceylin.log' ]; do sleep 2; done; tail -f '$AGENTS/logs/ceylin.log')" C-m

# Pane 2 (sol alt) — Pipeline durumu (canli)
tmux split-window -v -t "$SESSION:0.0"
tmux send-keys -t "$SESSION:0.2" "bash '$AGENTS/lib/status_watcher.sh' '$AGENTS'" C-m

# Pane 3 (sag alt) — Kanal mesajlari
tmux split-window -v -t "$SESSION:0.1"
tmux send-keys -t "$SESSION:0.3" "bash '$AGENTS/lib/channel_watcher.sh' '$AGENTS'" C-m

tmux select-layout -t "$SESSION:0" tiled

# === Pencere 2: Ekip Loglari ===

tmux new-window -t "$SESSION" -n "ekipler"

# Ismail logu
tmux send-keys -t "$SESSION:1.0" \
    "printf '\033[32m━━━ ISMAIL (Senior Dev) ━━━\033[0m\n'; tail -f '$AGENTS/logs/ismail.log' 2>/dev/null || (echo 'Bekleniyor...'; while ! [ -f '$AGENTS/logs/ismail.log' ]; do sleep 2; done; tail -f '$AGENTS/logs/ismail.log')" C-m

# Zeynep logu
tmux split-window -h -t "$SESSION:1.0"
tmux send-keys -t "$SESSION:1.1" \
    "printf '\033[35m━━━ ZEYNEP (UX Architect) ━━━\033[0m\n'; tail -f '$AGENTS/logs/zeynep.log' 2>/dev/null || (echo 'Bekleniyor...'; while ! [ -f '$AGENTS/logs/zeynep.log' ]; do sleep 2; done; tail -f '$AGENTS/logs/zeynep.log')" C-m

# Hasan logu
tmux split-window -v -t "$SESSION:1.0"
tmux send-keys -t "$SESSION:1.2" \
    "printf '\033[33m━━━ HASAN (Backend) ━━━\033[0m\n'; tail -f '$AGENTS/logs/hasan.log' 2>/dev/null || (echo 'Bekleniyor...'; while ! [ -f '$AGENTS/logs/hasan.log' ]; do sleep 2; done; tail -f '$AGENTS/logs/hasan.log')" C-m

# Saki logu
tmux split-window -v -t "$SESSION:1.1"
tmux send-keys -t "$SESSION:1.3" \
    "printf '\033[31m━━━ SAKI (Frontend) ━━━\033[0m\n'; tail -f '$AGENTS/logs/saki.log' 2>/dev/null || (echo 'Bekleniyor...'; while ! [ -f '$AGENTS/logs/saki.log' ]; do sleep 2; done; tail -f '$AGENTS/logs/saki.log')" C-m

tmux select-layout -t "$SESSION:1" tiled

# === Pencere 3: QA & DevOps ===

tmux new-window -t "$SESSION" -n "qa-devops"

# Ahmet logu
tmux send-keys -t "$SESSION:2.0" \
    "printf '\033[37m━━━ AHMET (QA / Reality Checker) ━━━\033[0m\n'; tail -f '$AGENTS/logs/ahmet.log' 2>/dev/null || (echo 'Bekleniyor...'; while ! [ -f '$AGENTS/logs/ahmet.log' ]; do sleep 2; done; tail -f '$AGENTS/logs/ahmet.log')" C-m

# Huseyin logu
tmux split-window -h -t "$SESSION:2.0"
tmux send-keys -t "$SESSION:2.1" \
    "printf '\033[38;5;208m━━━ HUSEYIN (DevOps) ━━━\033[0m\n'; tail -f '$AGENTS/logs/huseyin.log' 2>/dev/null || (echo 'Bekleniyor...'; while ! [ -f '$AGENTS/logs/huseyin.log' ]; do sleep 2; done; tail -f '$AGENTS/logs/huseyin.log')" C-m

tmux select-layout -t "$SESSION:2" tiled

# === Genel ayarlar ===
tmux set-option -t "$SESSION" status on
tmux set-option -t "$SESSION" status-style "bg=colour235,fg=colour255"
tmux set-option -t "$SESSION" status-left "#[fg=colour82,bold] YOUDOWN BRAIN v2 "
tmux set-option -t "$SESSION" status-right " #[fg=colour246]Ctrl+B 1/2/3=pencere | D=cik  %H:%M "

tmux select-window -t "$SESSION:0"
tmux select-pane -t "$SESSION:0.0"

echo ""
echo "╔═══════════════════════════════════════════════╗"
echo "║     YOUDOWN BRAIN v2 — Panel Baslatildi       ║"
echo "╠═══════════════════════════════════════════════╣"
echo "║  Ctrl+B 1 : Orkestrasyon (Ece+Ceylin+Durum)  ║"
echo "║  Ctrl+B 2 : Ekipler (Ismail+Zeynep+Hasan+Saki)║"
echo "║  Ctrl+B 3 : QA & DevOps (Ahmet+Huseyin)      ║"
echo "╠═══════════════════════════════════════════════╣"
echo "║  Ctrl+B ok : pane degistir                    ║"
echo "║  Ctrl+B D  : panelden cik                    ║"
echo "╚═══════════════════════════════════════════════╝"
echo ""
sleep 1
tmux attach -t "$SESSION"
