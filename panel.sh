#!/bin/bash
AGENTS="$(cd "$(dirname "$0")" && pwd)"
SESSION="agent-v2"

if tmux has-session -t "$SESSION" 2>/dev/null; then
    tmux attach -t "$SESSION"
    exit 0
fi

tmux new-session -d -s "$SESSION"

# Ece logu (sol üst)
tmux send-keys -t "$SESSION:0.0" "printf '\033[34m━━━ ECE (Mimar) ━━━\033[0m\n'; tail -f '$AGENTS/logs/ece.log' 2>/dev/null || (echo 'Log bekleniyor...'; while ! [ -f '$AGENTS/logs/ece.log' ]; do sleep 2; done; tail -f '$AGENTS/logs/ece.log')" C-m

# Ceylin logu (sağ üst)
tmux split-window -h -t "$SESSION:0.0"
tmux send-keys -t "$SESSION:0.1" "printf '\033[32m━━━ CEYLİN (Uygulayıcı) ━━━\033[0m\n'; tail -f '$AGENTS/logs/ceylin.log' 2>/dev/null || (echo 'Log bekleniyor...'; while ! [ -f '$AGENTS/logs/ceylin.log' ]; do sleep 2; done; tail -f '$AGENTS/logs/ceylin.log')" C-m

# Mesajlar (sol alt)
tmux split-window -v -t "$SESSION:0.0"
tmux send-keys -t "$SESSION:0.2" "bash '$AGENTS/lib/msg_watcher.sh' '$AGENTS/messages'" C-m

# Durum (sağ alt)
tmux split-window -v -t "$SESSION:0.1"
tmux send-keys -t "$SESSION:0.3" "bash '$AGENTS/lib/status_watcher.sh' '$AGENTS'" C-m

tmux select-layout -t "$SESSION" tiled
tmux set-option -t "$SESSION" status-style "bg=colour235,fg=colour255"
tmux set-option -t "$SESSION" status-left " ⚡ ECE & CEYLİN  "
tmux set-option -t "$SESSION" status-right " %H:%M "
tmux select-pane -t "$SESSION:0.0"
tmux attach -t "$SESSION"
