#!/bin/bash
# lib/channel_watcher.sh — Tum kanallardaki mesajlari canli gosterir
# Panel icin — her 3 saniyede gunceller

AGENTS_DIR="${1:-.}"
CHANNELS_DIR="$AGENTS_DIR/channels"

show_messages() {
    clear
    printf '\033[1;33m━━━ KANAL MESAJLARI ━━━\033[0m\n\n'

    for ch_dir in "$CHANNELS_DIR"/*/; do
        [ ! -d "$ch_dir" ] && continue
        local ch=$(basename "$ch_dir")
        local count=$(find "$ch_dir" -maxdepth 1 -name "*.json" 2>/dev/null | wc -l | tr -d ' ')
        [ "$count" = "0" ] && continue

        # Kanal renkleri
        case "$ch" in
            genel)    printf '\033[34m── %s (%s mesaj) ──\033[0m\n' "$ch" "$count" ;;
            tasarim)  printf '\033[32m── %s (%s mesaj) ──\033[0m\n' "$ch" "$count" ;;
            backend)  printf '\033[33m── %s (%s mesaj) ──\033[0m\n' "$ch" "$count" ;;
            qa)       printf '\033[31m── %s (%s mesaj) ──\033[0m\n' "$ch" "$count" ;;
            broadcast)printf '\033[35m── %s (%s mesaj) ──\033[0m\n' "$ch" "$count" ;;
            *)        printf '── %s (%s mesaj) ──\n' "$ch" "$count" ;;
        esac

        # Son 3 mesaji goster
        for f in $(find "$ch_dir" -maxdepth 1 -name "*.json" -print 2>/dev/null | sort -t'_' -k1 -n | tail -3); do
            local from=$(python3 -c "import json; print(json.load(open('$f'))['from'])" 2>/dev/null)
            local content=$(python3 -c "import json; c=json.load(open('$f'))['content']; print(c[:120]+'...' if len(c)>120 else c)" 2>/dev/null)
            local ts=$(python3 -c "import json; from datetime import datetime; print(datetime.fromtimestamp(json.load(open('$f'))['timestamp']).strftime('%H:%M:%S'))" 2>/dev/null)
            printf '  \033[90m%s\033[0m \033[1m%s:\033[0m %s\n' "$ts" "$from" "$content"
        done
        echo ""
    done

    # Handoff durumu
    local handoff_count=$(find "$AGENTS_DIR/handoffs" -maxdepth 1 -name "*.json" 2>/dev/null | wc -l | tr -d ' ')
    if [ "$handoff_count" -gt 0 ]; then
        printf '\033[36m── HANDOFFS (%s) ──\033[0m\n' "$handoff_count"
        for f in $(find "$AGENTS_DIR/handoffs" -maxdepth 1 -name "*.json" -print 2>/dev/null | sort | tail -5); do
            [ ! -f "$f" ] && continue
            local basename_f=$(basename "$f")
            # qa_ ile baslayanlar QA verdict
            if echo "$basename_f" | grep -q "^qa_"; then
                local verdict=$(python3 -c "import json; print(json.load(open('$f')).get('verdict','?'))" 2>/dev/null)
                local task_id=$(python3 -c "import json; print(json.load(open('$f')).get('task_id','?'))" 2>/dev/null)
                local icon=$( [ "$verdict" = "PASS" ] && echo "✅" || echo "❌" )
                printf '  %s QA #%s → %s\n' "$icon" "$task_id" "$verdict"
            else
                local from=$(python3 -c "import json; print(json.load(open('$f')).get('from','?'))" 2>/dev/null)
                local to=$(python3 -c "import json; print(json.load(open('$f')).get('to','?'))" 2>/dev/null)
                local status=$(python3 -c "import json; print(json.load(open('$f')).get('status','?'))" 2>/dev/null)
                local icon=$( [ "$status" = "completed" ] && echo "✅" || echo "📩" )
                printf '  %s %s → %s (%s)\n' "$icon" "$from" "$to" "$status"
            fi
        done
    fi
}

while true; do
    show_messages
    sleep 3
done
