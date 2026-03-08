#!/bin/bash
# Yeni bir gorev baslat — C+ Protocol
# Kullanim: ./start_task.sh "Gorev aciklamasi"
# Opsiyonel: ./start_task.sh "Gorev" --initiator mini

set -euo pipefail

AGENTS_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$AGENTS_DIR/lib/protocol.sh"

TASK="${1:?Kullanim: $0 \"Gorev aciklamasi\" [--initiator main|mini]}"
shift

INITIATOR="main"
while [[ $# -gt 0 ]]; do
    case $1 in
        --initiator) INITIATOR="$2"; shift 2 ;;
        *) shift ;;
    esac
done

# Eski mesajlari arsivle (silme, tasi)
if ls "$MESSAGES_DIR"/*.json &>/dev/null; then
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

log "SYSTEM" "Gorev baslatildi: $TASK (initiator=$INITIATOR)"

# initiator olmayan ilk konusur
if [ "$INITIATOR" = "main" ]; then
    FIRST="mini"
else
    FIRST="main"
fi

echo ""
echo "=== C+ Protocol — Gorev Baslatildi ==="
echo "Gorev: $TASK"
echo "Ilk konusan: $FIRST"
echo ""
echo "Baslatmak icin:"
echo "  Ana Mac:  cd $AGENTS_DIR && ./agent.sh --role main"
echo "  Mac Mini: cd $AGENTS_DIR && ./agent.sh --role mini"
echo ""
echo "Izlemek icin:"
echo "  tail -f $LOG_DIR/main.log"
echo "  tail -f $LOG_DIR/mini.log"
echo "  ls -la $MESSAGES_DIR/"
