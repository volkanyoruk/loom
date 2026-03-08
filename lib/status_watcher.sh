#!/bin/bash
# Durum paneli — panel sağ alt pane
AGENTS_DIR="$1"
STATUS_FILE="$AGENTS_DIR/task_status.json"

show_status() {
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  DURUM  ($(date '+%H:%M:%S'))"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if [ -f "$STATUS_FILE" ]; then
        STATUS_FILE="$STATUS_FILE" python3 - <<'PY'
import json, os, sys
path = os.environ['STATUS_FILE']
try:
    d = json.load(open(path))
    phase = d.get('phase', '?')
    task  = d.get('task', '')
    done  = d.get('steps_done', 0)
    total = d.get('steps_total', 0)
    print("Görev : " + task[:55])
    print("Faz   : " + phase)
    if total > 0:
        bar_len = 18
        filled = int(bar_len * done / total)
        bar = '█' * filled + '░' * (bar_len - filled)
        print("Adım  : [" + bar + "] " + str(done) + "/" + str(total))
    for s in d.get('steps', [])[-5:]:
        st = s.get('status', '')
        icon = '✅' if st == 'done' else ('🔄' if st == 'in_progress' else '⬜')
        print("  " + icon + " " + s.get('title', '')[:48])
except Exception as e:
    print("(okunamadı: " + str(e) + ")")
PY
    else
        echo "(görev yok — start_task.sh ile başlat)"
    fi

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  KOMUTLAR"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  ./start_task.sh \"görev\""
    echo "  ./youdown-brain.sh --role main --mode plan"
    echo "  ./youdown-brain.sh --role mini --mode qa"
    echo "  ./ask_mini.sh \"soru\""
    echo "  AI_BACKEND=gemini ./youdown-brain.sh ..."
    echo ""
    echo "  [Ctrl+B → ok tuşu] pane değiştir"
    echo "  [Ctrl+B D]         panelden çık"
}

while true; do
    clear
    show_status
    sleep 3
done
