#!/bin/bash
# youdown-brain.sh — Unified YouDown AI Brain v3
# Kullanım: ./youdown-brain.sh --role mini|main --mode qa|collab|auto|plan
#           ./youdown-brain.sh --status

set -euo pipefail

AGENTS="$(cd "$(dirname "$0")" && pwd)"
source "$AGENTS/lib/protocol.sh"

# === Defaults ===
MY_ROLE="" MODE="qa" POLL=2 MAX_IDLE=300
CONTEXT_SIZE=35000 PROJECT_ROOT="$(cd "$AGENTS/.." && pwd)"
CLAUDE="${CLAUDE_BIN:-$(find "$HOME/.local/bin" "$HOME/.npm-global/bin" /usr/local/bin /opt/homebrew/bin -name claude -type f 2>/dev/null | head -1)}"
[[ -z "$CLAUDE" ]] && CLAUDE="$(which claude 2>/dev/null || true)"
MODEL="${CLAUDE_MODEL:-claude-opus-4-6}"
STATUS_FILE="$AGENTS/task_status.json"
BUILD_MAX_RETRY=3

# === Args ===
SHOW_STATUS=false
while [[ $# -gt 0 ]]; do
    case $1 in
        --role)    MY_ROLE="$2"; shift 2 ;;
        --mode)    MODE="$2"; shift 2 ;;
        --poll)    POLL="$2"; shift 2 ;;
        --context) CONTEXT_SIZE="$2"; shift 2 ;;
        --status)  SHOW_STATUS=true; shift ;;
        --help)
            echo "Kullanım: $0 --role main|mini --mode qa|collab|auto|plan"
            echo "  qa     : Soru-cevap daemon (ask_mini.sh ile)"
            echo "  collab : Turn-based işbirliği"
            echo "  auto   : Otonom (build + kod yazma)"
            echo "  plan   : Görevi analiz et → alt adımlara böl → uygula"
            echo ""
            echo "Durum: $0 --status"
            exit 0 ;;
        *) shift ;;
    esac
done

# --status: rol gerektirmez
if $SHOW_STATUS; then
    if [[ -f "$STATUS_FILE" ]]; then
        python3 - "$STATUS_FILE" << 'PY'
import json, sys
from datetime import datetime

data = json.load(open(sys.argv[1]))
phase_icons = {"research":"🔍","planning":"📋","implementation":"⚙️",
               "review":"👁","testing":"🧪","done":"✅","failed":"❌"}
step_icons = {"pending":"⏳","in_progress":"🔄","done":"✅","failed":"❌","skipped":"⏭"}

print(f"\n{'='*60}")
print(f"  YOUDOWN BRAIN — GÖREV DURUMU")
print(f"{'='*60}")
print(f"  Görev : {data.get('task','—')}")
phase = data.get('phase','—')
print(f"  Faz   : {phase_icons.get(phase,'?')} {phase}")
total = data.get('steps_total',0)
done  = data.get('steps_done',0)
bar   = '█' * done + '░' * (total - done) if total > 0 else ''
pct   = int(done/total*100) if total > 0 else 0
print(f"  İlerleme: [{bar}] {done}/{total} (%{pct})")
print(f"{'─'*60}")
for s in data.get('steps',[]):
    icon = step_icons.get(s['status'],'?')
    assignee = f"[{s.get('assignee','?')}]"
    retry = f" (retry:{s['retry_count']})" if s.get('retry_count',0) > 0 else ""
    print(f"  {icon} Step {s['id']}: {s['desc']} {assignee}{retry}")
    if s.get('error_summary'):
        print(f"       ⚠ {s['error_summary']}")
blockers = data.get('blockers',[])
if blockers:
    print(f"{'─'*60}")
    print(f"  🚧 Blocker: {', '.join(blockers)}")
print(f"{'='*60}\n")
PY
    else
        echo "Henüz görev yok. 'start_task.sh' ile başlat."
    fi
    exit 0
fi

[[ -z "$MY_ROLE" ]] && echo "Hata: --role gerekli (main|mini) veya --status kullan" && exit 1
[[ "$MY_ROLE" != "main" && "$MY_ROLE" != "mini" ]] && echo "Hata: role = main|mini" && exit 1
[[ "$MODE" != "qa" && "$MODE" != "collab" && "$MODE" != "auto" && "$MODE" != "plan" ]] && \
    echo "Hata: mode = qa|collab|auto|plan" && exit 1
[[ ! -x "$CLAUDE" ]] && echo "Hata: Claude bulunamadı: $CLAUDE" && exit 1

PEER_ROLE=$([[ "$MY_ROLE" == "main" ]] && echo "mini" || echo "main")
INBOX="$AGENTS/ask_mini.txt"
OUTBOX="$AGENTS/mini_reply.txt"
BUSY="$AGENTS/.mini_busy"

# ================================================================
# === Status Yönetimi ===
# ================================================================
init_task_status() {
    local task="$1"
    python3 - "$STATUS_FILE" "$task" << 'PY'
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
print(data["task_id"])
PY
}

update_task_status() {
    local key="$1" value="$2"
    [[ ! -f "$STATUS_FILE" ]] && return
    python3 - "$STATUS_FILE" "$key" "$value" << 'PY'
import json, sys
from datetime import datetime, timezone
path, key, value = sys.argv[1], sys.argv[2], sys.argv[3]
data = json.load(open(path))
data[key] = value
data["updated_at"] = datetime.now(timezone.utc).isoformat()
json.dump(data, open(path,'w'), ensure_ascii=False, indent=2)
PY
}

save_plan_steps() {
    # Temp script dosyası + JSON stdin pipe — heredoc/pipe stdin çakışması yok
    local plan_json="$1"
    local script; script=$(mktemp)
    cat > "$script" << 'PY'
import json, sys
from datetime import datetime, timezone

path = sys.argv[1]
plan = json.load(sys.stdin)
data = json.load(open(path))

steps = []
for i, s in enumerate(plan.get("steps", []), 1):
    steps.append({
        "id": i,
        "desc": s.get("desc",""),
        "assignee": "mini",
        "affected_files": s.get("affected_files", []),
        "test_plan": s.get("test_plan",""),
        "status": "pending",
        "build_result": None,
        "test_result": None,
        "retry_count": 0,
        "error_summary": None
    })

data["steps"] = steps
data["steps_total"] = len(steps)
data["steps_done"] = 0
data["current_step_id"] = 1
data["phase"] = "implementation"
data["analysis"] = plan.get("analysis","")
data["acceptance_criteria"] = plan.get("acceptance_criteria",[])
data["updated_at"] = datetime.now(timezone.utc).isoformat()
json.dump(data, open(path,'w'), ensure_ascii=False, indent=2)
print(f"Plan kaydedildi: {len(steps)} adım")
PY
    printf '%s' "$plan_json" | python3 "$script" "$STATUS_FILE"
    rm -f "$script"
}

update_step_status() {
    local step_id="$1" status="$2" error_summary="${3:-}"
    [[ ! -f "$STATUS_FILE" ]] && return
    python3 - "$STATUS_FILE" "$step_id" "$status" "$error_summary" << 'PY'
import json, sys
from datetime import datetime, timezone
path, sid, status, err = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
data = json.load(open(path))
for s in data["steps"]:
    if s["id"] == sid:
        s["status"] = status
        if err:
            s["error_summary"] = err
        if status == "done":
            data["steps_done"] = data.get("steps_done", 0) + 1
            # Sonraki adıma geç
            next_id = sid + 1
            if next_id <= data["steps_total"]:
                data["current_step_id"] = next_id
            else:
                data["phase"] = "done"
        elif status == "in_progress":
            data["current_step_id"] = sid
            data["phase"] = "implementation"
        break
data["updated_at"] = datetime.now(timezone.utc).isoformat()
json.dump(data, open(path,'w'), ensure_ascii=False, indent=2)
PY
}

record_build() {
    local step_id="$1" success="$2" error_type="${3:-}"
    [[ ! -f "$STATUS_FILE" ]] && return
    python3 - "$STATUS_FILE" "$step_id" "$success" "$error_type" << 'PY'
import json, sys
from datetime import datetime, timezone
path, sid, ok, etype = sys.argv[1], int(sys.argv[2]), sys.argv[3]=="true", sys.argv[4]
data = json.load(open(path))
data.setdefault("build_history",[]).append({
    "step_id": sid, "success": ok,
    "error_type": etype,
    "timestamp": datetime.now(timezone.utc).isoformat()
})
json.dump(data, open(path,'w'), ensure_ascii=False, indent=2)
PY
}

# ================================================================
# === System Prompts ===
# ================================================================
qa_prompt() {
    local history="$1" question="$2"
    cat << EOF
Sen YouDown projesinin $MY_ROLE Claude'usun (Opus 4.6). Swift 6 + SwiftUI + yt-dlp + ffmpeg.
Kısa, teknik, Türkçe cevap ver. Kod yazarken tam çalışır Swift 6 yaz.

=== KONUŞMA GEÇMİŞİ ===
$history

=== SORU ===
$question
EOF
}

plan_prompt() {
    local task="$1" file_tree="$2"
    cat << EOF
Sen bir Swift 6/SwiftUI proje mimarısısın. Görevi analiz et ve JSON plan üret.

GÖREV: $task

PROJE DOSYA YAPISI:
$file_tree

Sadece aşağıdaki JSON formatını döndür, başka hiçbir şey yazma:
{
  "analysis": "Görevin 2-3 cümlelik teknik analizi",
  "acceptance_criteria": ["Kriter 1", "Kriter 2"],
  "risks": ["Risk 1"],
  "steps": [
    {
      "id": 1,
      "desc": "Ne yapılacak (tek dosya veya tek mantıksal birim)",
      "affected_files": ["Sources/Dosya.swift"],
      "test_plan": "Bu adım nasıl doğrulanır"
    }
  ]
}

KURALLAR:
- Her adım tek bir dosya veya tek bir özellik
- Adımlar bağımlılık sırasıyla: model → service → viewmodel → view
- Swift 6 strict concurrency uyumlu ol
- Max 8 adım
EOF
}

collab_prompt() {
    local context="$1" files="$2" step_info="${3:-}"
    if [[ "$MY_ROLE" == "main" ]]; then
        cat << EOF
Sen YouDown ARCHITECT Claude'usun (Ana Mac, Opus 4.6).
Mac Mini'nin kodunu review et, eksikleri tamamla, tüm iş bitince [TAMAMLANDI] yaz. Türkçe.
$step_info

=== PROJE DOSYALARI ===
$files

=== KONUŞMA ===
$context

Sıra sende:
EOF
    else
        cat << EOF
Sen YouDown IMPLEMENTER Claude'usun (Mac Mini, Opus 4.6).
Görevi analiz et, tam çalışır Swift 6 kodu yaz, [TAMAMLANDI] ile bitir. Türkçe.
KOD FORMATI: ### Sources/Dosya.swift ardından \`\`\`swift blok \`\`\`
$step_info

=== PROJE DOSYALARI ===
$files

=== KONUŞMA ===
$context

Sıra sende:
EOF
    fi
}

build_fix_prompt() {
    local errors="$1" affected_files="$2"
    cat << EOF
Sen YouDown IMPLEMENTER Claude'usun (Mac Mini, Opus 4.6).
Swift build HATALI. Hataları düzelt, sadece değişen dosyaları döndür. Türkçe.
KOD FORMATI: ### Sources/Dosya.swift ardından \`\`\`swift blok \`\`\`

=== BUILD HATALARI ===
$errors

=== ETKİLENEN DOSYALAR ===
$affected_files

Hataları düzelt:
EOF
}

# ================================================================
# === Proje Dosyaları & Build ===
# ================================================================
read_project_files() {
    while IFS= read -r path; do
        [[ -f "$path" ]] && printf '### %s\n```swift\n%s\n```\n\n' \
            "${path#$PROJECT_ROOT/}" "$(cat "$path")"
    done < <(find "$PROJECT_ROOT/Sources" -name "*.swift" 2>/dev/null | sort)
    [[ -f "$PROJECT_ROOT/Package.swift" ]] && printf '### Package.swift\n```swift\n%s\n```\n\n' \
        "$(cat "$PROJECT_ROOT/Package.swift")"
}

get_file_tree() {
    find "$PROJECT_ROOT/Sources" -name "*.swift" 2>/dev/null | \
        sed "s|$PROJECT_ROOT/||" | sort
}

read_affected_files() {
    local file_list="$1"  # newline-separated paths
    printf '%s' "$file_list" | while IFS= read -r f; do
        local full="$PROJECT_ROOT/$f"
        [[ -f "$full" ]] && printf '### %s\n```swift\n%s\n```\n\n' "$f" "$(cat "$full")"
    done
}

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

# Build + hata parse → yapılandırılmış çıktı
run_build_with_feedback() {
    local out ec=0
    out=$(cd "$PROJECT_ROOT" && swift build 2>&1) || ec=$?

    if [[ $ec -eq 0 ]]; then
        printf 'BUILD_SUCCESS\n'
        return 0
    fi

    # Hataları parse et
    printf '%s' "$out" | python3 - << 'PY'
import sys, re

COMPILE = re.compile(
    r'^(?P<file>[^\s:]+\.swift):(?P<line>\d+):\d+:\s*(?P<level>error|warning):\s*(?P<msg>.+)$',
    re.MULTILINE
)
CONCURRENCY = re.compile(
    r'non-sendable|actor-isolated|cannot be transferred|@Sendable|main actor-isolated',
    re.IGNORECASE
)

text = sys.stdin.read()
errors = []
files_seen = set()

for m in COMPILE.finditer(text):
    d = m.groupdict()
    if d['level'] != 'error':
        continue
    msg = d['msg']
    if CONCURRENCY.search(msg):
        d['category'] = 'CONCURRENCY'
    elif 'cannot find' in msg or 'has no member' in msg:
        d['category'] = 'REFERENCE'
    elif 'cannot convert' in msg or 'cannot assign' in msg:
        d['category'] = 'TYPE_ERROR'
    else:
        d['category'] = 'SYNTAX'
    errors.append(d)
    files_seen.add(d['file'].split('/')[-1])

print('BUILD_FAILED')
print(f'ERROR_COUNT:{len(errors)}')
print(f'AFFECTED_FILES:{",".join(sorted(files_seen))}')
print('---ERRORS---')
for e in errors[:20]:  # max 20 hata
    print(f"[{e['category']}] {e['file'].split('/')[-1]}:{e['line']} — {e['msg']}")
print('---RAW_TAIL---')
# Son 30 satır ham çıktı
lines = text.strip().split('\n')
for l in lines[-30:]:
    print(l)
PY
    return 1
}

# ================================================================
# === QA Modu ===
# ================================================================
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

        > "$INBOX"; touch "$BUSY"
        last_checksum=""
        log "$MY_ROLE" "Soru #$q_count: ${question:0:80}..."

        send_msg "main_qa" "$question"
        local history
        history=$(get_context $((CONTEXT_SIZE / 2)))

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

# ================================================================
# === Collab Modu ===
# ================================================================
run_collab() {
    log "$MY_ROLE" "=== Collab Modu | $MODEL ==="
    local idle=0 step_info="${1:-}"

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
        reply=$(call_claude "$MY_ROLE" "$(collab_prompt "$context" "$files" "$step_info")") || \
            { log "$MY_ROLE" "Claude hata."; break; }

        printf '%s' "$reply" | grep -q '```swift' && {
            apply_code "$reply" | while read -r l; do log "$MY_ROLE" "  $l"; done
        }

        send_msg "$MY_ROLE" "$reply"
        log "$MY_ROLE" "Mesaj (${#reply} chars)"

        printf '%s' "$reply" | grep -q '\[TAMAMLANDI\]' && { log "$MY_ROLE" "TAMAMLANDI!"; break; }
        sleep "$POLL"
    done
}

# ================================================================
# === Auto Modu (Build Feedback Loop) ===
# ================================================================
run_auto() {
    log "$MY_ROLE" "=== Auto Modu | $MODEL ==="
    local idle=0 step_info="${1:-}"

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
        local context files=""
        context=$(get_context "$CONTEXT_SIZE")
        local seq; seq=$(get_last_seq)
        [[ $seq -le 4 ]] && files=$(read_project_files)

        # Main: build feedback
        local build_section=""
        if [[ "$MY_ROLE" == "main" ]]; then
            local build_out
            build_out=$(run_build_with_feedback) || true
            local build_status; build_status=$(printf '%s' "$build_out" | head -1)

            if [[ "$build_status" == "BUILD_SUCCESS" ]]; then
                build_section="=== BUILD: ✅ BAŞARILI ==="
            else
                build_section="=== BUILD: ❌ HATA ===
$(printf '%s' "$build_out" | tail -n +2 | head -40)"
            fi
        fi

        local reply
        reply=$(call_claude "$MY_ROLE" "$(collab_prompt "$context" "$files" "$step_info")
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

# ================================================================
# === Plan Modu — Sadece main çalıştırır ===
# ================================================================
run_plan() {
    [[ "$MY_ROLE" != "main" ]] && {
        log "$MY_ROLE" "Plan modu sadece main rolünde çalışır."
        exit 1
    }

    # Görev al
    local task=""
    if [[ -f "$STATUS_FILE" ]]; then
        task=$(python3 -c "import json; print(json.load(open('$STATUS_FILE')).get('task',''))" 2>/dev/null)
    fi
    if [[ -z "$task" ]]; then
        log "$MY_ROLE" "Görev bulunamadı. Önce: ./start_task.sh \"Görev açıklaması\""
        exit 1
    fi

    log "$MY_ROLE" "=== Plan Modu | Görev: ${task:0:60}... ==="
    local tid; tid=$(init_task_status "$task")
    log "$MY_ROLE" "Task ID: $tid"

    # Dosya ağacı
    local file_tree; file_tree=$(get_file_tree)

    # Faz 1: Planlama — Ana Mac JSON plan üretir
    log "$MY_ROLE" "📋 Plan oluşturuluyor..."
    update_task_status "phase" "planning"

    local plan_reply
    plan_reply=$(call_claude "$MY_ROLE" "$(plan_prompt "$task" "$file_tree")")

    # JSON'u parse et
    local plan_json
    plan_json=$(printf '%s' "$plan_reply" | python3 -c "
import sys, json, re
text = sys.stdin.read()
# Markdown code block içindeyse çıkar
m = re.search(r'\`\`\`(?:json)?\s*(\{.*?\})\s*\`\`\`', text, re.DOTALL)
if m:
    text = m.group(1)
else:
    # Direkt JSON bul
    m = re.search(r'\{.*\}', text, re.DOTALL)
    if m: text = m.group(0)
try:
    parsed = json.loads(text)
    print(json.dumps(parsed, ensure_ascii=False))
except Exception as e:
    print(f'PARSE_ERROR:{e}', file=sys.stderr)
    sys.exit(1)
" 2>/dev/null) || {
        log "$MY_ROLE" "HATA: Plan JSON parse edilemedi. Ham yanıt:"
        log "$MY_ROLE" "${plan_reply:0:200}"
        exit 1
    }

    # Planı kaydet
    save_plan_steps "$plan_json"
    log "$MY_ROLE" "Plan kaydedildi."

    # Planı göster
    printf '\n%s\n' "$(python3 - "$STATUS_FILE" << 'PY'
import json, sys
data = json.load(open(sys.argv[1]))
print(f"📋 ANALİZ: {data.get('analysis','')}")
print(f"✅ KRITERLER: {', '.join(data.get('acceptance_criteria',[]))}")
print(f"\n📝 ADIMLAR ({data['steps_total']}):")
for s in data['steps']:
    files = ', '.join(s.get('affected_files',[]))
    print(f"  {s['id']}. {s['desc']}")
    print(f"     Dosyalar: {files}")
PY
)"

    # Mini'ye planı gönder — env var ile, stdin çakışması yok
    local plan_summary
    plan_summary=$(PLAN_JSON="$plan_json" python3 << 'PY'
import json, os
data = json.loads(os.environ['PLAN_JSON'])
steps = data.get('steps',[])
text = f"Görev: {data.get('analysis','')}\n\nAdımlar:\n"
for s in steps:
    text += f"{s['id']}. {s['desc']} ({', '.join(s.get('affected_files',[]))})\n"
print(text)
PY
)

    send_msg "main" "PLAN HAZIR — Başlıyoruz.\n\n$plan_summary\n\nİmplementasyona geç."

    # Faz 2: Her adım için collab döngüsü
    local steps_total
    steps_total=$(python3 -c "import json; print(json.load(open('$STATUS_FILE'))['steps_total'])" "$STATUS_FILE" 2>/dev/null)

    for step_id in $(seq 1 "$steps_total"); do
        local step_desc step_files
        step_desc=$(python3 -c "
import json, sys
data = json.load(open(sys.argv[1]))
for s in data['steps']:
    if s['id'] == $step_id:
        print(s['desc'])
        break
" "$STATUS_FILE")
        step_files=$(python3 -c "
import json, sys
data = json.load(open(sys.argv[1]))
for s in data['steps']:
    if s['id'] == $step_id:
        print('\n'.join(s.get('affected_files',[])))
        break
" "$STATUS_FILE")

        log "$MY_ROLE" "▶ Adım $step_id/$steps_total: $step_desc"
        update_step_status "$step_id" "in_progress"

        local step_info="=== MEVCUT ADIM: $step_id/$steps_total ===
$step_desc
Etkilenen dosyalar: $step_files"

        # Build retry loop
        local build_ok=false
        for attempt in $(seq 1 $BUILD_MAX_RETRY); do
            # Collab: mini yazar, main review eder
            run_collab "$step_info"

            # Build kontrol
            if [[ "$MY_ROLE" == "main" ]]; then
                local bout
                bout=$(run_build_with_feedback) || true
                local bstatus; bstatus=$(printf '%s' "$bout" | head -1)

                if [[ "$bstatus" == "BUILD_SUCCESS" ]]; then
                    record_build "$step_id" "true" ""
                    build_ok=true
                    break
                else
                    local err_summary; err_summary=$(printf '%s' "$bout" | grep "^\[" | head -5 | tr '\n' ' ')
                    record_build "$step_id" "false" "$err_summary"
                    log "$MY_ROLE" "Build başarısız (deneme $attempt/$BUILD_MAX_RETRY): $err_summary"

                    if [[ $attempt -lt $BUILD_MAX_RETRY ]]; then
                        # Hata feedback'i Mini'ye gönder
                        local affected_content; affected_content=$(read_affected_files "$step_files")
                        local fix_reply
                        fix_reply=$(call_claude "mini" "$(build_fix_prompt "$bout" "$affected_content")") || true
                        printf '%s' "$fix_reply" | grep -q '```swift' && {
                            apply_code "$fix_reply" | while read -r l; do log "$MY_ROLE" "  FIX: $l"; done
                            send_msg "mini" "$fix_reply"
                        }
                    fi
                fi
            else
                # Mini: sadece build loop olmayan adımda bekle
                build_ok=true
                break
            fi
        done

        if $build_ok; then
            update_step_status "$step_id" "done"
            log "$MY_ROLE" "✅ Adım $step_id tamamlandı"
        else
            update_step_status "$step_id" "failed" "Build $BUILD_MAX_RETRY denemede düzeltilemedi"
            log "$MY_ROLE" "❌ Adım $step_id başarısız — devam ediliyor"
        fi
    done

    update_task_status "phase" "done"
    log "$MY_ROLE" "=== Plan modu tamamlandı ==="
    "$0" --status
}

# ================================================================
# === Signal & Başlangıç ===
# ================================================================
trap 'log "$MY_ROLE" "Durduruluyor..."; exit 0' SIGINT SIGTERM

log "$MY_ROLE" "=== YouDown Brain v3 | role=$MY_ROLE mode=$MODE model=$MODEL ==="

case "$MODE" in
    qa)     run_qa ;;
    collab) run_collab ;;
    auto)   run_auto ;;
    plan)   run_plan ;;
esac

log "$MY_ROLE" "=== Durdu ==="
