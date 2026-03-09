#!/bin/bash
# Yeni bir gorev baslat — Multi-Agent Pipeline
# Kullanim: ./start_task.sh "Gorev aciklamasi" [--project /path/to/project]

set -euo pipefail

AGENTS_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$AGENTS_DIR/lib/protocol.sh"

TASK="${1:?Kullanim: $0 \"Gorev aciklamasi\" [--project /path]}"
shift

PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$AGENTS_DIR/.." && pwd)}"
while [[ $# -gt 0 ]]; do
    case $1 in
        --project) PROJECT_ROOT="$2"; shift 2 ;;
        *) shift ;;
    esac
done

# Eski mesajlari arsivle
ARCHIVE_DIR="$AGENTS_DIR/archive/$(date +%Y%m%d_%H%M%S)"
has_old=false

# Tum kanallardaki mesajlari arsivle
for ch_dir in "$CHANNELS_DIR"/*/; do
    [ ! -d "$ch_dir" ] && continue
    if find "$ch_dir" -maxdepth 1 -name "*.json" 2>/dev/null | grep -q .; then
        local_ch=$(basename "$ch_dir")
        mkdir -p "$ARCHIVE_DIR/$local_ch"
        mv "$ch_dir"/*.json "$ARCHIVE_DIR/$local_ch/" 2>/dev/null || true
        has_old=true
    fi
done

# Handoff'lari arsivle
if find "$HANDOFFS_DIR" -maxdepth 1 -name "*.json" 2>/dev/null | grep -q .; then
    mkdir -p "$ARCHIVE_DIR/handoffs"
    mv "$HANDOFFS_DIR"/*.json "$ARCHIVE_DIR/handoffs/" 2>/dev/null || true
    has_old=true
fi

# Eski messages/ klasorunu de arsivle (geriye uyumluluk)
if find "$AGENTS_DIR/messages" -maxdepth 1 -name "*.json" 2>/dev/null | grep -q .; then
    mkdir -p "$ARCHIVE_DIR/messages"
    mv "$AGENTS_DIR/messages"/*.json "$ARCHIVE_DIR/messages/" 2>/dev/null || true
    has_old=true
fi

if $has_old; then
    log "SYSTEM" "Eski mesajlar arsivlendi: $ARCHIVE_DIR"
fi

# Heartbeat dosyalarini temizle
rm -f "$CHANNELS_DIR"/.heartbeat_* 2>/dev/null || true
rm -f "$AGENTS_DIR/messages"/.heartbeat_* 2>/dev/null || true

# Bootstrap mesaji — genel kanala yaz
BOOTSTRAP_JSON=$(
    export _TS="$(date +%s)" _PROJECT_ROOT="$PROJECT_ROOT"
    printf '%s' "$TASK" | python3 -c "
import json, sys, os
msg = {
    'seq': 0,
    'from': 'system',
    'channel': 'genel',
    'timestamp': int(os.environ['_TS']),
    'content': sys.stdin.read(),
    'initiator': 'ece',
    'project_root': os.environ['_PROJECT_ROOT'],
    'checksum': '0'
}
print(json.dumps(msg, ensure_ascii=False, indent=2))
"
)

write_atomic "$(channel_dir genel)/000_system_$(date +%s).json" "$BOOTSTRAP_JSON"

# task_status.json'a gorevi kaydet
export _STATUS_FILE="$AGENTS_DIR/task_status.json"
printf '%s' "$TASK" | python3 -c "
import json, sys, uuid, os
from datetime import datetime, timezone
task_text = sys.stdin.read()
data = {
    'task_id': str(uuid.uuid4())[:8],
    'task': task_text,
    'phase': 'planning',
    'created_at': datetime.now(timezone.utc).isoformat(),
    'updated_at': datetime.now(timezone.utc).isoformat(),
    'steps': [],
    'steps_total': 0,
    'steps_done': 0,
    'current_step_id': 0,
    'blockers': [],
    'build_history': [],
    'lessons': [],
    'qa_stats': {
        'total_tests': 0,
        'first_pass_rate': 0,
        'avg_retries': 0,
        'escalations': 0
    }
}
json.dump(data, open(os.environ['_STATUS_FILE'], 'w'), ensure_ascii=False, indent=2)
"

log "SYSTEM" "Gorev baslatildi: $TASK"

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║     YOUDOWN BRAIN — Gorev Baslatildi         ║"
echo "╠══════════════════════════════════════════════╣"
echo "  Gorev   : $TASK"
echo "  Proje   : $PROJECT_ROOT"
echo "╠══════════════════════════════════════════════╣"
echo "  Baslatma komutlari:                          "
echo "                                               "
echo "  1) Ece plan olustursun:                      "
echo "     ./youdown-brain.sh --role ece --mode pipeline \\"
echo "       --project $PROJECT_ROOT"
echo "                                               "
echo "  2) Ceylin dagitsin ve yonetsin:              "
echo "     ./youdown-brain.sh --role ceylin --mode pipeline \\"
echo "       --project $PROJECT_ROOT"
echo "                                               "
echo "  Veya tek komutla:                            "
echo "     ./run_pipeline.sh \"$TASK\" --project $PROJECT_ROOT"
echo "                                               "
echo "  Panel:  ./panel.sh                           "
echo "  Durum:  ./youdown-brain.sh --status          "
echo "╚══════════════════════════════════════════════╝"
echo ""
