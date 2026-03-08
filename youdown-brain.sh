#!/bin/bash
# youdown-brain.sh — Unified YouDown AI Brain v2
# Ana Mac + Mac Mini için tek script, 3 mod
# Kullanım: ./youdown-brain.sh --role mini|main --mode qa|collab|auto

set -euo pipefail

AGENTS="$(cd "$(dirname "$0")" && pwd)"
source "$AGENTS/lib/protocol.sh"

# === Defaults ===
MY_ROLE="" MODE="qa" POLL=2 MAX_IDLE=300
CONTEXT_SIZE=35000 PROJECT_ROOT="$(cd "$AGENTS/.." && pwd)"
CLAUDE="${CLAUDE_BIN:-$HOME/.local/bin/claude}"
MODEL="${CLAUDE_MODEL:-claude-opus-4-6}"

# === Args ===
while [[ $# -gt 0 ]]; do
    case $1 in
        --role)    MY_ROLE="$2"; shift 2 ;;
        --mode)    MODE="$2"; shift 2 ;;
        --poll)    POLL="$2"; shift 2 ;;
        --context) CONTEXT_SIZE="$2"; shift 2 ;;
        --help)
            echo "Kullanım: $0 --role main|mini --mode qa|collab|auto"
            echo "  qa     : Soru-cevap daemon (ask_mini.sh ile)"
            echo "  collab : Turn-based işbirliği"
            echo "  auto   : Tam otonom (build + kod yazma)"
            exit 0 ;;
        *) shift ;;
    esac
done

[[ -z "$MY_ROLE" ]] && echo "Hata: --role gerekli (main|mini)" && exit 1
[[ "$MY_ROLE" != "main" && "$MY_ROLE" != "mini" ]] && echo "Hata: role = main|mini" && exit 1
[[ "$MODE" != "qa" && "$MODE" != "collab" && "$MODE" != "auto" ]] && echo "Hata: mode = qa|collab|auto" && exit 1

# Preflight
[[ ! -x "$CLAUDE" ]] && echo "Hata: Claude bulunamadı: $CLAUDE" && exit 1

PEER_ROLE=$([[ "$MY_ROLE" == "main" ]] && echo "mini" || echo "main")
INBOX="$AGENTS/ask_mini.txt"
OUTBOX="$AGENTS/mini_reply.txt"
BUSY="$AGENTS/.mini_busy"

# === System Prompts ===
qa_prompt() {
    local history="$1" question="$2"
    cat << EOF
Sen YouDown projesinin $MY_ROLE Claude'usun (Opus 4.6). Swift 6 + SwiftUI + yt-dlp + ffmpeg.
Ana Mac Claude sorular soruyor. Kısa, teknik, Türkçe cevap ver.
Kod yazarken tam çalışır Swift 6 yaz.

=== KONUŞMA GEÇMİŞİ ===
$history

=== SORU ===
$question
EOF
}

collab_prompt() {
    local context="$1" files="$2"
    if [[ "$MY_ROLE" == "main" ]]; then
        cat << EOF
Sen YouDown ARCHITECT Claude'usun (Ana Mac, Opus 4.6).
Mac Mini'nin kodunu review et, eksikleri tamamla, [TAMAMLANDI] ile bitir. Türkçe.

=== PROJE DOSYALARI ===
$files

=== KONUŞMA ===
$context

Sıra sende:
EOF
    else
        cat << EOF
Sen YouDown IMPLEMENTER Claude'usun (Mac Mini, Opus 4.6).
Gorevi analiz et, Swift kodu yaz, [TAMAMLANDI] ile bitir. Türkçe.
KOD FORMATI: ### Sources/Dosya.swift + \`\`\`swift blok\`\`\`

=== PROJE DOSYALARI ===
$files

=== KONUŞMA ===
$context

Sıra sende:
EOF
    fi
}

# === Proje dosyaları (dinamik) ===
read_project_files() {
    while IFS= read -r path; do
        [[ -f "$path" ]] && printf '### %s\n```swift\n%s\n```\n\n' \
            "${path#$PROJECT_ROOT/}" "$(cat "$path")"
    done < <(find "$PROJECT_ROOT/Sources" -name "*.swift" 2>/dev/null | sort)
    [[ -f "$PROJECT_ROOT/Package.swift" ]] && printf '### Package.swift\n```swift\n%s\n```\n\n' \
        "$(cat "$PROJECT_ROOT/Package.swift")"
}

# === Kod uygula (path traversal korumalı) ===
apply_code() {
    local reply="$1"
    printf '%s' "$reply" | PROJECT_ROOT="$PROJECT_ROOT" python3 - << 'PY'
import sys, re, os
content = sys.stdin.read()
root = os.path.realpath(os.environ['PROJECT_ROOT'])
for path, code in re.findall(r'###\s+(Sources/[^\n]+\.swift)\n```swift\n(.*?)```', content, re.DOTALL):
    full = os.path.realpath(os.path.join(root, path.strip()))
    if not full.startswith(root + os.sep):
        print(f"SKIP (path traversal): {path.strip()}")
        continue
    os.makedirs(os.path.dirname(full), exist_ok=True)
    open(full, 'w').write(code)
    print(f"WROTE: {path.strip()}")
PY
}

# === Build ===
run_build() {
    local out ec=0
    out=$(cd "$PROJECT_ROOT" && swift build -c release 2>&1) || ec=$?
    [[ $ec -eq 0 ]] && printf 'BUILD_SUCCESS\n%s' "$out" || printf 'BUILD_FAILED\n%s' "$out"
}

# call_ai() kaldırıldı — protocol.sh'daki call_claude() kullanılıyor (retry + backoff dahil)

# === QA modu (mini daemon) ===
run_qa() {
    log "$MY_ROLE" "=== QA Modu başladı | $MODEL ==="
    log "$MY_ROLE" "Inbox: $INBOX | Dinleniyor..."

    > "$INBOX" 2>/dev/null || true; rm -f "$OUTBOX" "$BUSY"
    local last_checksum="" q_count=0

    while true; do
        touch_heartbeat "$MY_ROLE"
        local question
        question=$(cat "$INBOX" 2>/dev/null | tr -d '\0')
        [[ -z "$question" ]] && { sleep "$POLL"; continue; }

        local checksum
        checksum=$(printf '%s' "$question" | cksum | cut -d' ' -f1)
        [[ "$checksum" == "$last_checksum" ]] && { sleep "$POLL"; continue; }
        last_checksum="$checksum"
        q_count=$((q_count + 1))

        # Inbox hemen temizle (last_checksum sıfırla ki aynı soru tekrar sorulabilsin)
        > "$INBOX"; touch "$BUSY"
        last_checksum=""
        log "$MY_ROLE" "Soru #$q_count: ${question:0:80}..."

        # Soruyu messages/'a kaydet (geçmiş için)
        send_msg "main_qa" "$question"

        # Context yükle
        local history
        history=$(get_context $((CONTEXT_SIZE / 2)))

        # Claude çağır
        local reply
        if reply=$(call_claude "$MY_ROLE" "$(qa_prompt "$history" "$question")"); then
            write_atomic "$OUTBOX" "$reply"
            send_msg "$MY_ROLE" "$reply"
            log "$MY_ROLE" "Cevap gönderildi (${#reply} chars)"
        else
            write_atomic "$OUTBOX" "[Hata: Claude cevap üretemedi]"
            log "$MY_ROLE" "WARN: Boş cevap"
        fi
        rm -f "$BUSY"
    done
}

# === Collab modu ===
run_collab() {
    log "$MY_ROLE" "=== Collab Modu | $MODEL ==="
    local idle=0

    while true; do
        touch_heartbeat "$MY_ROLE"
        check_conflicts || { sleep 10; continue; }
        check_seq_integrity || true

        if ! is_my_turn "$MY_ROLE"; then
            idle=$((idle + 1))
            [[ $idle -ge $MAX_IDLE ]] && { log "$MY_ROLE" "TIMEOUT"; break; }
            [[ $((idle % 10)) -eq 0 ]] && { check_peer_alive "$PEER_ROLE" 180 || true; }
            sleep "$POLL"; continue
        fi

        idle=0
        local seq context files=""
        seq=$(get_last_seq)
        context=$(get_context "$CONTEXT_SIZE")
        [[ $seq -le 4 ]] && files=$(read_project_files)

        local reply
        reply=$(call_claude "$MY_ROLE" "$(collab_prompt "$context" "$files")") || { log "$MY_ROLE" "Claude hata."; break; }

        printf '%s' "$reply" | grep -q '```swift' && {
            apply_code "$reply" | while read -r l; do log "$MY_ROLE" "  $l"; done
        }

        send_msg "$MY_ROLE" "$reply"
        log "$MY_ROLE" "Mesaj (${#reply} chars)"

        printf '%s' "$reply" | grep -q '\[TAMAMLANDI\]' && { log "$MY_ROLE" "TAMAMLANDI!"; break; }
        sleep "$POLL"
    done
}

# === Auto modu ===
run_auto() {
    log "$MY_ROLE" "=== Auto Modu | $MODEL ==="
    local idle=0

    while true; do
        touch_heartbeat "$MY_ROLE"
        check_conflicts || { sleep 10; continue; }
        check_seq_integrity || true

        if ! is_my_turn "$MY_ROLE"; then
            idle=$((idle + 1))
            [[ $idle -ge $MAX_IDLE ]] && break
            sleep "$POLL"; continue
        fi

        idle=0
        local context files="" build_section=""
        context=$(get_context "$CONTEXT_SIZE")
        local seq; seq=$(get_last_seq)
        [[ $seq -le 4 ]] && files=$(read_project_files)

        [[ "$MY_ROLE" == "main" ]] && {
            local bout; bout=$(run_build)
            build_section="=== BUILD ===
$(printf '%s' "$bout" | head -1)
$(printf '%s' "$bout" | tail -n +2 | head -60)"
        }

        local reply
        reply=$(call_claude "$MY_ROLE" "$(collab_prompt "$context" "$files")
$build_section") || break

        printf '%s' "$reply" | grep -q '```swift' && {
            apply_code "$reply" | while read -r l; do log "$MY_ROLE" "  $l"; done
        }

        send_msg "$MY_ROLE" "$reply"

        printf '%s' "$reply" | grep -q '\[TAMAMLANDI\]' && { log "$MY_ROLE" "TAMAMLANDI!"; break; }
        sleep "$POLL"
    done
    log "$MY_ROLE" "=== Auto durdu ==="
}

# === Signal ===
trap 'log "$MY_ROLE" "Durduruluyor..."; exit 0' SIGINT SIGTERM

log "$MY_ROLE" "=== YouDown Brain v2 | role=$MY_ROLE mode=$MODE model=$MODEL ==="

case "$MODE" in
    qa)     run_qa ;;
    collab) run_collab ;;
    auto)   run_auto ;;
esac

log "$MY_ROLE" "=== Durdu ==="
