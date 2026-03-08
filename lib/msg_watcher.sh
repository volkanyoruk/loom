#!/bin/bash
# Mesaj logu — panel sol alt pane
MESSAGES_DIR="$1"

show_msgs() {
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  MESAJLAR  ($(date '+%H:%M:%S'))"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    for f in $(ls -1 "$MESSAGES_DIR"/*.json 2>/dev/null | sort -t'_' -k1 -n | tail -15); do
        from=$(python3 -c "import json; d=json.load(open('$f')); print(d['from'])" 2>/dev/null)
        content=$(python3 -c "import json; d=json.load(open('$f')); print(d['content'][:100])" 2>/dev/null)
        seq=$(basename "$f" | cut -d'_' -f1)
        case "$from" in
            main*) color="\033[34m" ;;
            mini*) color="\033[32m" ;;
            system) color="\033[33m" ;;
            *) color="\033[0m" ;;
        esac
        printf "${color}[%s] %-12s\033[0m %s\n" "$seq" "$from" "$content"
    done
}

while true; do
    clear
    show_msgs
    sleep 2
done
