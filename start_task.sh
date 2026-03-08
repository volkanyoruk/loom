#!/bin/bash
# Yeni bir gorev baslat — C+ Protocol
# Kullanim: ./start_task.sh "Gorev aciklamasi"
# Opsiyonel: ./start_task.sh "Gorev" --initiator mini

set -euo pipefail

AGENTS_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$AGENTS_DIR/lib/protocol.sh"

TASK="${1:?Kullanim: $0 \"Gorev aciklamasi\" [--initiator ece|ceylin]}"
shift

INITIATOR="ece"
while [[ $# -gt 0 ]]; do
    case $1 in
        --initiator) INITIATOR="$2"; shift 2 ;;
        *) shift ;;
    esac
done

# Eski mesajlari arsivle (silme, tasi)
if ls "$MESSAGES_DIR"/*.json 2>/dev/null | grep -q .; then
    ARCHIVE_DIR="$AGENTS_DIR/archive/$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$ARCHIVE_DIR"
    mv "$MESSAGES_DIR"/*.json "$ARCHIVE_DIR/"
    log "SYSTEM" "Eski mesajlar arsivlendi: $ARCHIVE_DIR"
fi

# Heartbeat dosyalarini temizle
rm -f "$MESSAGES_DIR"/.heartbeat_*

# Bootstrap mesaji (pipe ile — shell expansion safe)
BOOTSTRAP_JSON=$(printf '%s' "$TASK" | python3 -c "
import json, sys
msg = {
    'seq': 0,
    'from': 'system',
    'timestamp': $(date +%s),
    'content': sys.stdin.read(),
    'initiator': '$INITIATOR',
    'checksum': '0'
}
print(json.dumps(msg, ensure_ascii=False, indent=2))
")

write_atomic "$MESSAGES_DIR/000_system_$(date +%s).json" "$BOOTSTRAP_JSON"

# task_status.json'a görevi kaydet
python3 - "$AGENTS_DIR/task_status.json" "$TASK" << 'PY'
import json, sys, uuid
from datetime import datetime, timezone
path, task = sys.argv[1], sys.argv[2]
data = {
    "task_id": str(uuid.uuid4())[:8],
    "task": task,
    "phase": "planning",
    "created_at": datetime.now(timezone.utc).isoformat(),
    "updated_at": datetime.now(timezone.utc).isoformat(),
    "steps": [],
    "steps_total": 0,
    "steps_done": 0,
    "current_step_id": 0,
    "blockers": [],
    "build_history": [],
    "lessons": []
}
json.dump(data, open(path, 'w'), ensure_ascii=False, indent=2)
PY

log "SYSTEM" "Gorev baslatildi: $TASK (initiator=$INITIATOR)"

# initiator olmayan ilk konusur
if [ "$INITIATOR" = "ece" ]; then
    FIRST="ceylin"
else
    FIRST="ece"
fi

echo ""
echo "=== YouDown Brain — Görev Başlatıldı ==="
echo "Görev  : $TASK"
echo "İlk    : $FIRST"
echo ""
echo "Başlatmak için:"
echo "  Plan modu : ./youdown-brain.sh --role ece --mode plan"
echo "  Collab    : ./youdown-brain.sh --role ece --mode collab"
echo "  Ceylin    : ./youdown-brain.sh --role ceylin --mode collab"
echo ""
echo "Durum takibi:"
echo "  ./youdown-brain.sh --status"
echo "  tail -f $LOG_DIR/ece.log"
