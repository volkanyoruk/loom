#!/bin/bash
# agents/lib/protocol.sh — C+ Protocol Core v2
# Multi-channel JSON messaging with atomic writes, seq-based turns, retry logic
# Kanal destegi: her ekip kendi mesaj klasorunde haberlesir

AGENTS_DIR="${AGENTS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
CHANNELS_DIR="$AGENTS_DIR/channels"
LOG_DIR="$AGENTS_DIR/logs"
HANDOFFS_DIR="$AGENTS_DIR/handoffs"
AGENTS_DEFS_DIR="$AGENTS_DIR/agents"
TEAMS_DIR="$AGENTS_DIR/teams"

mkdir -p "$LOG_DIR" "$HANDOFFS_DIR"

# Varsayilan kanal
ACTIVE_CHANNEL="${ACTIVE_CHANNEL:-genel}"

# === Kanal dizinini dondur ===
channel_dir() {
    local ch="${1:-$ACTIVE_CHANNEL}"
    local dir="$CHANNELS_DIR/$ch"
    mkdir -p "$dir"
    printf '%s' "$dir"
}

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
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    local role_lower
    role_lower=$(echo "$role" | tr '[:upper:]' '[:lower:]')
    printf '[%s] [%s] %s\n' "$ts" "$role" "$msg" >> "$LOG_DIR/${role_lower}.log"
    printf '[%s] [%s] %s\n' "$ts" "$role" "$msg"
}

# === Ajan prompt dosyasini oku ===
get_agent_prompt() {
    local agent_name="$1"
    local agent_file="$AGENTS_DEFS_DIR/${agent_name}.md"
    if [ -f "$agent_file" ]; then
        cat "$agent_file"
    else
        echo "Ajan tanimi bulunamadi: $agent_name"
    fi
}

# === Ekip bilgisini oku ===
get_team_info() {
    local team_name="$1"
    local team_file="$TEAMS_DIR/${team_name}.json"
    if [ -f "$team_file" ]; then
        cat "$team_file"
    else
        echo "{}"
    fi
}

# === Ajanin hangi ekipte oldugunu bul ===
get_agent_team() {
    local agent_name="$1"
    local f
    for f in "$TEAMS_DIR"/*.json; do
        [[ ! -f "$f" ]] && continue
        if python3 -c "import json,sys; d=json.load(open(sys.argv[1])); exit(0 if sys.argv[2] in d.get('members',[]) else 1)" "$f" "$agent_name" 2>/dev/null; then
            python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['channel'])" "$f"
            return
        fi
    done
    echo "genel"
}

# === Seq Management (kanal bazli) ===
get_last_file() {
    local ch_dir
    ch_dir=$(channel_dir "${1:-$ACTIVE_CHANNEL}")
    find "$ch_dir" -maxdepth 1 -name "*.json" -print 2>/dev/null | while IFS= read -r f; do
        printf '%s\t%s\n' "$(basename "$f" | cut -d'_' -f1)" "$f"
    done | sort -n -k1 | tail -1 | cut -f2-
}

get_last_from() {
    local last
    last=$(get_last_file "${1:-$ACTIVE_CHANNEL}")
    [ -z "$last" ] && echo "none" && return
    basename "$last" | cut -d'_' -f2
}

get_last_seq() {
    local last
    last=$(get_last_file "${1:-$ACTIVE_CHANNEL}")
    [ -z "$last" ] && echo "0" && return
    local raw
    raw=$(basename "$last" | cut -d'_' -f1 | sed 's/^0*//')
    echo "${raw:-0}"
}

next_seq() {
    local ch_dir
    ch_dir=$(channel_dir "${1:-$ACTIVE_CHANNEL}")
    local lockdir="$ch_dir/.seq.lock"
    local waited=0
    while ! mkdir "$lockdir" 2>/dev/null; do
        waited=$((waited + 1))
        if [ $waited -ge 5 ]; then
            log "SYSTEM" "WARN: seq lock timeout, forcing lock"
            rm -rf "$lockdir"
            mkdir "$lockdir" 2>/dev/null || true
            break
        fi
        sleep 1
    done
    local last_seq
    last_seq=$(get_last_seq "${1:-$ACTIVE_CHANNEL}")
    local result
    result=$(printf '%03d' $((last_seq + 1)))
    rm -rf "$lockdir"
    printf '%s' "$result"
}

# === Turn Check (kanal bazli) ===
is_my_turn() {
    local my_role="$1" channel="${2:-$ACTIVE_CHANNEL}"
    local last_from
    last_from=$(get_last_from "$channel")

    if [ "$last_from" = "none" ]; then
        return 1
    fi

    if [ "$last_from" = "system" ]; then
        local last_file
        last_file=$(get_last_file "$channel")
        [ -z "$last_file" ] && return 1
        local initiator
        initiator=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('initiator',''))" "$last_file" 2>/dev/null) || true
        [ "$initiator" != "$my_role" ] && return 0 || return 1
    fi

    [ "$last_from" != "$my_role" ] && return 0 || return 1
}

# === Send Message (kanal bazli, env ile guvenli) ===
send_msg() {
    local role="$1" content="$2" channel="${3:-$ACTIVE_CHANNEL}"
    local ch_dir
    ch_dir=$(channel_dir "$channel")
    local seq
    seq=$(next_seq "$channel")
    local ts
    ts=$(date +%s)
    local checksum
    checksum=$(printf '%s' "$content" | cksum | cut -d' ' -f1)
    local filename="${seq}_${role}_${ts}.json"

    local json
    json=$(
        export _SEQ="$seq" _ROLE="$role" _CHANNEL="$channel" _TS="$ts" _CHECKSUM="$checksum" _MSG_CONTENT="$content"
        python3 -c "
import json, os
msg = {
    'seq': int(os.environ['_SEQ']),
    'from': os.environ['_ROLE'],
    'channel': os.environ['_CHANNEL'],
    'timestamp': int(os.environ['_TS']),
    'content': os.environ['_MSG_CONTENT'],
    'checksum': os.environ['_CHECKSUM']
}
print(json.dumps(msg, ensure_ascii=False, indent=2))
" < /dev/null
    )

    write_atomic "$ch_dir/$filename" "$json"
    log "$role" "[$channel] Mesaj gonderildi: $filename (${#content} chars)"
}

# === Broadcast Message (tum kanallara) ===
broadcast_msg() {
    local role="$1" content="$2"
    send_msg "$role" "$content" "broadcast"
    log "$role" "BROADCAST mesaj gonderildi"
}

# === Context Window (kanal bazli, son N char) ===
get_context() {
    local max_chars=${1:-60000} channel="${2:-$ACTIVE_CHANNEL}"
    local ch_dir
    ch_dir=$(channel_dir "$channel")
    local total=0
    local msgs=()

    local f
    for f in $(find "$ch_dir" -maxdepth 1 -name "*.json" -print 2>/dev/null | sort -t'_' -k1 -rn); do
        local size
        size=$(wc -c < "$f" | tr -d ' ')
        total=$((total + size))
        [ $total -gt $max_chars ] && break
        msgs=("$f" "${msgs[@]+"${msgs[@]}"}")
    done

    for f in "${msgs[@]+"${msgs[@]}"}"; do
        local from content label
        from=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['from'])" "$f" 2>/dev/null) || continue
        content=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['content'])" "$f" 2>/dev/null) || continue
        label=$(echo "$from" | tr '[:lower:]' '[:upper:]')
        printf '**%s:** %s\n\n---\n\n' "$label" "$content"
    done
}

# === Handoff Olustur ===
create_handoff() {
    local from="$1" to="$2" task_id="$3" task_desc="$4" context="$5"
    local team
    team=$(get_agent_team "$to")
    local ts
    ts=$(date +%s)
    # Atomik seq: lock ile
    local lockdir="$HANDOFFS_DIR/.handoff.lock"
    local waited=0
    while ! mkdir "$lockdir" 2>/dev/null; do
        waited=$((waited + 1))
        if [ $waited -ge 5 ]; then
            rm -rf "$lockdir"
            mkdir "$lockdir" 2>/dev/null || true
            break
        fi
        sleep 1
    done
    local seq
    seq=$(find "$HANDOFFS_DIR" -maxdepth 1 -name "*.json" -not -name "qa_*" 2>/dev/null | wc -l | tr -d ' ')
    seq=$(printf '%03d' $((seq + 1)))
    rm -rf "$lockdir"

    local filename="${seq}_${from}_to_${to}_${ts}.json"

    local json
    json=$(
        export _SEQ="$seq" _FROM="$from" _TO="$to" _TEAM="$team" _TASK_ID="$task_id" _TS="$ts" _TASK_DESC="$task_desc" _CONTEXT="$context"
        python3 -c "
import json, os
handoff = {
    'seq': int(os.environ['_SEQ']),
    'from': os.environ['_FROM'],
    'to': os.environ['_TO'],
    'team': os.environ['_TEAM'],
    'task_id': int(os.environ['_TASK_ID']),
    'task_desc': os.environ['_TASK_DESC'],
    'context': os.environ['_CONTEXT'],
    'timestamp': int(os.environ['_TS']),
    'status': 'pending'
}
print(json.dumps(handoff, ensure_ascii=False, indent=2))
" < /dev/null
    )

    write_atomic "$HANDOFFS_DIR/$filename" "$json"
    send_msg "$from" "HANDOFF: Gorev #$task_id $to icin: $task_desc" "$team"
    log "$from" "Handoff olusturuldu: $from → $to (task #$task_id)"
}

# === QA Gate ===
create_qa_verdict() {
    local task_id="$1" verdict="$2" attempt="$3" details="$4"
    local ts
    ts=$(date +%s)
    local filename="qa_${task_id}_attempt${attempt}_${ts}.json"

    local json
    json=$(
        export _TASK_ID="$task_id" _VERDICT="$verdict" _ATTEMPT="$attempt" _TS="$ts" _DETAILS="$details"
        python3 -c "
import json, os
v = {
    'task_id': int(os.environ['_TASK_ID']),
    'verdict': os.environ['_VERDICT'],
    'attempt': int(os.environ['_ATTEMPT']),
    'timestamp': int(os.environ['_TS']),
    'details': os.environ['_DETAILS']
}
print(json.dumps(v, ensure_ascii=False, indent=2))
" < /dev/null
    )

    write_atomic "$HANDOFFS_DIR/$filename" "$json"
    log "AHMET" "QA Verdict: task #$task_id → $verdict (attempt $attempt/3)"
}

# === Seq Gap Check (kanal bazli) ===
check_seq_integrity() {
    local channel="${1:-$ACTIVE_CHANNEL}"
    local ch_dir
    ch_dir=$(channel_dir "$channel")
    local expected=0
    local f
    for f in $(find "$ch_dir" -maxdepth 1 -name "*.json" -print 2>/dev/null | sort -t'_' -k1 -n); do
        local seq_num
        seq_num=$(basename "$f" | cut -d'_' -f1 | sed 's/^0*//')
        [ -z "$seq_num" ] && seq_num=0
        if [ "$seq_num" -ne "$expected" ]; then
            log "SYSTEM" "[$channel] SEQ GAP: expected $expected, got $seq_num"
            return 1
        fi
        expected=$((expected + 1))
    done
    return 0
}

# === AI Call with Retry ===
MAX_RETRIES=3
BACKOFF=(5 15 30)

call_claude() {
    local role="$1" prompt="$2"
    local bin="${CLAUDE_BIN:-$(which claude 2>/dev/null || find "$HOME/.local/bin" "$HOME/.npm-global/bin" /usr/local/bin /opt/homebrew/bin -name claude 2>/dev/null | head -1)}"
    local model="${CLAUDE_MODEL:-claude-sonnet-4-6}"

    # Ajan kisilik promptunu ekle
    local agent_prompt
    agent_prompt=$(get_agent_prompt "$role")
    local full_prompt="${agent_prompt}

---

${prompt}"

    local tmp
    tmp=$(mktemp /tmp/yd_prompt.XXXXXX)
    printf '%s' "$full_prompt" > "$tmp"

    local i
    for i in $(seq 0 $((MAX_RETRIES - 1))); do
        local reply
        local exit_code=0
        reply=$(env -u CLAUDECODE "$bin" --model "$model" -p "$(cat "$tmp")" 2>>"$LOG_DIR/${role}_stderr.log") || exit_code=$?

        if [ $exit_code -eq 0 ] && [ -n "$reply" ] && [ ${#reply} -gt 20 ]; then
            rm -f "$tmp"
            printf '%s' "$reply"
            return 0
        fi

        local wait_time=${BACKOFF[$i]}
        log "$role" "WARN: attempt $((i+1))/$MAX_RETRIES failed (exit=$exit_code, len=${#reply}). ${wait_time}s bekleniyor..."
        sleep "$wait_time"
    done

    rm -f "$tmp"
    log "$role" "FATAL: Claude $MAX_RETRIES denemede cevap veremedi."
    return 1
}

# === Heartbeat ===
touch_heartbeat() {
    local role="$1"
    touch "$CHANNELS_DIR/.heartbeat_${role}"
}

check_peer_alive() {
    local peer_role="$1"
    local timeout=${2:-120}
    local hb_file="$CHANNELS_DIR/.heartbeat_${peer_role}"

    [ ! -f "$hb_file" ] && return 0

    # macOS + Linux uyumlu: date -r (her ikisinde de calisir)
    local last_mod
    last_mod=$(date -r "$hb_file" +%s 2>/dev/null || stat -f %m "$hb_file" 2>/dev/null || echo 0)
    local now
    now=$(date +%s)
    local delta=$((now - last_mod))

    if [ $delta -gt $timeout ]; then
        log "SYSTEM" "Peer '$peer_role' ${delta}s sessiz (timeout=${timeout}s)"
        return 1
    fi
    return 0
}

# === Pipeline Durumu ===
get_pipeline_status() {
    local status_file="$AGENTS_DIR/task_status.json"
    [ ! -f "$status_file" ] && echo "{}" && return
    cat "$status_file"
}

update_pipeline_status() {
    local field="$1" value="$2"
    local status_file="$AGENTS_DIR/task_status.json"
    export _FIELD="$field" _VALUE="$value" _STATUS_FILE="$status_file"
    python3 -c "
import json, os
from datetime import datetime, timezone
sf = os.environ['_STATUS_FILE']
data = json.load(open(sf)) if os.path.exists(sf) else {}
field = os.environ['_FIELD']
value = os.environ['_VALUE']
try:
    value = int(value)
except ValueError:
    pass
data[field] = value
data['updated_at'] = datetime.now(timezone.utc).isoformat()
json.dump(data, open(sf, 'w'), ensure_ascii=False, indent=2)
" < /dev/null || true
}

# === Tum kanallardaki mesaj sayisi ===
channel_stats() {
    local ch_dir
    for ch_dir in "$CHANNELS_DIR"/*/; do
        [ ! -d "$ch_dir" ] && continue
        local ch
        ch=$(basename "$ch_dir")
        local count
        count=$(find "$ch_dir" -maxdepth 1 -name "*.json" 2>/dev/null | wc -l | tr -d ' ')
        printf '%s: %s mesaj\n' "$ch" "$count"
    done
}
