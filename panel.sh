#!/bin/bash
# youdown-brain panel — 4 bölmeli tmux arayüzü
# Kullanım: ./panel.sh

AGENTS_DIR="$(cd "$(dirname "$0")" && pwd)"
SESSION="youdown"

# Zaten çalışan session varsa ona bağlan
if tmux has-session -t "$SESSION" 2>/dev/null; then
    echo "Panel zaten çalışıyor, bağlanıyor..."
    tmux attach -t "$SESSION"
    exit 0
fi

# ── tmux session kur ──────────────────────────────────────────────
tmux new-session -d -s "$SESSION"

# Pane 0 (sol üst) — MAIN log
tmux send-keys -t "$SESSION:0.0" \
    "printf '\\033[34m=== MAIN LOG ===\\033[0m\\n'; tail -f '$AGENTS_DIR/logs/main.log' 2>/dev/null || (echo 'Log bekleniyor...'; sleep 2; exec bash $0)" C-m

# Pane 1 (sağ üst) — MINI log
tmux split-window -h -t "$SESSION:0.0"
tmux send-keys -t "$SESSION:0.1" \
    "printf '\\033[32m=== MINI LOG ===\\033[0m\\n'; tail -f '$AGENTS_DIR/logs/mini.log' 2>/dev/null || (echo 'Log bekleniyor...'; while true; do sleep 2; [ -f \"$AGENTS_DIR/logs/mini.log\" ] && exec tail -f \"$AGENTS_DIR/logs/mini.log\"; done)" C-m

# Pane 2 (sol alt) — Mesajlar
tmux split-window -v -t "$SESSION:0.0"
tmux send-keys -t "$SESSION:0.2" "bash '$AGENTS_DIR/lib/msg_watcher.sh' '$AGENTS_DIR/messages'" C-m

# Pane 3 (sağ alt) — Durum + Komutlar
tmux split-window -v -t "$SESSION:0.1"
tmux send-keys -t "$SESSION:0.3" "bash '$AGENTS_DIR/lib/status_watcher.sh' '$AGENTS_DIR'" C-m

# Eşit 4'lü layout
tmux select-layout -t "$SESSION" tiled

# Status bar
tmux set-option -t "$SESSION" status on
tmux set-option -t "$SESSION" status-style "bg=colour235,fg=colour255"
tmux set-option -t "$SESSION" status-left "#[fg=colour82,bold] ⚡ youdown-brain  "
tmux set-option -t "$SESSION" status-right "  #[fg=colour246]%H:%M  Ctrl+B D = çık "

# Kullanıcı pane'ini seç (sol üst — main log, oradan komut çalıştırabilir)
tmux select-pane -t "$SESSION:0.0"

echo ""
echo "╔═══════════════════════════════════════╗"
echo "║    youdown-brain panel başlatıldı     ║"
echo "╠═══════════════════════════════════════╣"
echo "║  Sol üst  → MAIN agent log            ║"
echo "║  Sağ üst  → MINI agent log            ║"
echo "║  Sol alt  → Mesajlar (canlı)          ║"
echo "║  Sağ alt  → Durum + Komutlar          ║"
echo "╠═══════════════════════════════════════╣"
echo "║  Ctrl+B → ok tuşu  : pane değiştir   ║"
echo "║  Ctrl+B D           : panelden çık    ║"
echo "╚═══════════════════════════════════════╝"
echo ""
sleep 1
tmux attach -t "$SESSION"
