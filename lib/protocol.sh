#!/bin/bash
# agents/lib/protocol.sh — C+ Protocol Core
# Structured JSON messaging with atomic writes, seq-based turns, retry logic

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MESSAGES_DIR="$AGENTS_DIR/messages"
LOG_DIR="$AGENTS_DIR/logs"

mkdir -p "$MESSAGES_DIR" "$LOG_DIR"

# === Atomic Write (tmp + mv pattern) ===
write_atomic() {
    local target="$1" content="$2"
    local tmp="${target}.tmp.$$"
    printf '%s' "$content" > "$tmp"
    mv "$tmp" "$target"
}

# === Logging ===
log() {
    local role="$1" msg="$2"
    local ts=$(date '+%Y-%m-%d %H:%M:%S')
    printf '[%s] [%s] %s\n' "$ts" "$role" "$msg" >> "$LOG_DIR/${role}.log"
    printf '[%s] [%s] %s\n' "$ts" "$role" "$msg"
}

# === Seq Management ===
get_last_file() {
    # Seq number'a gore numerik siralama (dosya adinin basindan parse)
    ls -1 "$MESSAGES_DIR"/*.json 2>/dev/null | while IFS= read -r f; do
        printf '%s\t%s\n' "$(basename "$f" | cut -d'_' -f1)" "$f"
    done | sort -n -k1 | tail -1 | cut -f2-
}

get_last_from() {
    local last=$(get_last_file)
    [ -z "$last" ] && echo "none" && return
    basename "$last" | cut -d'_' -f2
}

get_last_seq() {
    local last=$(get_last_file)
    [ -z "$last" ] && echo "0" && return
    local raw=$(basename "$last" | cut -d'_' -f1 | sed 's/^0*//')
    echo "${raw:-0}"
}

next_seq() {
    # mkdir atomik lock — macOS/Linux portable, race condition yok
    local lockdir="$MESSAGES_DIR/.seq.lock"
    local waited=0
    while ! mkdir "$lockdir" 2>/dev/null; do
        waited=$((waited + 1))
        [ $waited -ge 5 ] && break   # max 5s bekle
        sleep 1
    done
    local result
    result=$(printf '%03d' $(($(get_last_seq) + 1)))
    rm -rf "$lockdir"
    printf '%s' "$result"
}

# === Turn Check ===
is_my_turn() {
    local my_role="$1"
    local last_from=$(get_last_from)

    # Henuz mesaj yok
    if [ "$last_from" = "none" ]; then
        return 1
    fi

    # Bootstrap: system mesaji var, initiator olmayan baslar
    if [ "$last_from" = "system" ]; then
        local last_file=$(get_last_file)
        local initiator=$(python3 -c "import json; print(json.load(open('$last_file'))['initiator'])" 2>/dev/null)
        [ "$initiator" != "$my_role" ] && return 0 || return 1
    fi

    # Normal: son yazan ben degilsem sira bende
    [ "$last_from" != "$my_role" ] && return 0 || return 1
}

# === Send Message ===
send_msg() {
    local role="$1" content="$2"
    local seq=$(next_seq)
    local ts=$(date +%s)
    local checksum=$(printf '%s' "$content" | cksum | cut -d' ' -f1)
    local filename="${seq}_${role}_${ts}.json"

    # JSON olustur (python3 ile escape-safe, pipe ile — heredoc expansion riski yok)
    local json=$(printf '%s' "$content" | python3 -c "
import json, sys
msg = {
    'seq': int('$seq'),
    'from': '$role',
    'timestamp': int('$ts'),
    'content': sys.stdin.read(),
    'checksum': '$checksum'
}
print(json.dumps(msg, ensure_ascii=False, indent=2))
")

    write_atomic "$MESSAGES_DIR/$filename" "$json"
    log "$role" "Mesaj gonderildi: $filename (${#content} chars)"
}

# === Context Window (son N char, sliding window) ===
get_context() {
    local max_chars=${1:-60000}
    local total=0
    local msgs=()

    for f in $(ls -1 "$MESSAGES_DIR"/*.json 2>/dev/null | sort -t'_' -k1 -rn); do
        local size=$(wc -c < "$f" | tr -d ' ')
        total=$((total + size))
        [ $total -gt $max_chars ] && break
        msgs=("$f" "${msgs[@]+"${msgs[@]}"}")
    done

    # Mesajlari conversation formatinda dondur
    for f in "${msgs[@]+"${msgs[@]}"}"; do
        local from=$(python3 -c "import json; print(json.load(open('$f'))['from'])")
        local content=$(python3 -c "import json; print(json.load(open('$f'))['content'])")
        local label
        case "$from" in
            ece*)    label="ECE" ;;
            ceylin*) label="CEYLİN" ;;
            system)  label="SYSTEM" ;;
            *)       label=$(echo "$from" | tr '[:lower:]' '[:upper:]') ;;
        esac
        printf '**%s:** %s\n\n---\n\n' "$label" "$content"
    done
}

# === Seq Gap Check ===
check_seq_integrity() {
    local expected=0
    for f in $(ls -1 "$MESSAGES_DIR"/*.json 2>/dev/null | sort -t'_' -k1 -n); do
        local seq=$(basename "$f" | cut -d'_' -f1 | sed 's/^0*//')
        [ -z "$seq" ] && seq=0
        if [ "$seq" -ne "$expected" ]; then
            log "SYSTEM" "SEQ GAP: expected $expected, got $seq (file: $(basename $f))"
            return 1
        fi
        expected=$((expected + 1))
    done
    return 0
}

# === Syncthing Conflict Check ===
check_conflicts() {
    local conflicts=$(ls "$MESSAGES_DIR"/*.sync-conflict-* 2>/dev/null)
    if [ -n "$conflicts" ]; then
        log "SYSTEM" "SYNCTHING CONFLICT detected: $conflicts"
        return 1
    fi
    return 0
}

# === AI Call with Retry ===
MAX_RETRIES=3
BACKOFF=(5 15 30)

call_claude() {
    local role="$1" prompt="$2"
    local bin="${CLAUDE_BIN:-$(which claude 2>/dev/null || find "$HOME/.local/bin" "$HOME/.npm-global/bin" /usr/local/bin /opt/homebrew/bin -name claude 2>/dev/null | head -1)}"
    local model="${CLAUDE_MODEL:-claude-sonnet-4-6}"

    for i in $(seq 0 $((MAX_RETRIES - 1))); do
        local reply
        reply=$(env -u CLAUDECODE "$bin" --model "$model" -p "$prompt" 2>>"$LOG_DIR/${role}_stderr.log")
        local exit_code=$?

        if [ $exit_code -eq 0 ] && [ -n "$reply" ] && [ ${#reply} -gt 20 ]; then
            printf '%s' "$reply"
            return 0
        fi

        local wait=${BACKOFF[$i]}
        log "$role" "WARN: attempt $((i+1))/$MAX_RETRIES failed (exit=$exit_code, len=${#reply}). ${wait}s bekleniyor..."
        sleep "$wait"
    done

    log "$role" "FATAL: Claude $MAX_RETRIES denemede cevap veremedi."
    return 1
}

# === Heartbeat ===
touch_heartbeat() {
    local role="$1"
    touch "$MESSAGES_DIR/.heartbeat_${role}"
}

check_peer_alive() {
    local peer_role="$1"
    local timeout=${2:-120}
    local hb_file="$MESSAGES_DIR/.heartbeat_${peer_role}"

    [ ! -f "$hb_file" ] && return 0  # Henuz heartbeat yok, ilk baslangic

    local last_mod=$(stat -f %m "$hb_file" 2>/dev/null || echo 0)
    local now=$(date +%s)
    local delta=$((now - last_mod))

    if [ $delta -gt $timeout ]; then
        log "SYSTEM" "Peer '$peer_role' ${delta}s sessiz (timeout=${timeout}s)"
        return 1
    fi
    return 0
}
