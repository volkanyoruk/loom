#!/bin/bash
# youdown-brain.sh — Multi-Agent Pipeline System
# 8 ajan, 4 ekip, kanal bazli haberlesme, Dev↔QA dongusu
#
# Kullanim:
#   ./youdown-brain.sh --role ece --mode pipeline     # Ece: plan olustur
#   ./youdown-brain.sh --role ceylin --mode pipeline   # Ceylin: dagit ve takip et
#   ./youdown-brain.sh --role ismail --mode worker      # Worker: gorev yap
#   ./youdown-brain.sh --role ahmet --mode qa           # QA: test et
#   ./youdown-brain.sh --status                         # Durum goster
#   ./youdown-brain.sh --channels                       # Kanal durumu

set -euo pipefail

AGENTS="$(cd "$(dirname "$0")" && pwd)"
AGENTS_DIR="$AGENTS"
export AGENTS_DIR
source "$AGENTS/lib/protocol.sh"
source "$AGENTS/lib/orchestrator.sh"
source "$AGENTS/lib/qa_gate.sh"
source "$AGENTS/lib/handoff.sh"

# === Defaults ===
MY_ROLE="" MODE="worker" POLL=3 MAX_IDLE=600
CONTEXT_SIZE=35000 PROJECT_ROOT="${PROJECT_ROOT:-$(cd "$AGENTS/.." && pwd)}"
CLAUDE="${CLAUDE_BIN:-$(which claude 2>/dev/null || find "$HOME/.local/bin" "$HOME/.npm-global/bin" /usr/local/bin /opt/homebrew/bin -name claude 2>/dev/null | head -1)}"
MODEL="${CLAUDE_MODEL:-claude-sonnet-4-6}"
STATUS_FILE="$AGENTS/task_status.json"

# === Tum roller ===
ALL_ROLES="ece ceylin ismail zeynep hasan saki ahmet huseyin"

# === Args ===
SHOW_STATUS=false
SHOW_CHANNELS=false
while [[ $# -gt 0 ]]; do
    case $1 in
        --role)     MY_ROLE="$2"; shift 2 ;;
        --mode)     MODE="$2"; shift 2 ;;
        --poll)     POLL="$2"; shift 2 ;;
        --context)  CONTEXT_SIZE="$2"; shift 2 ;;
        --project)  PROJECT_ROOT="$2"; shift 2 ;;
        --status)   SHOW_STATUS=true; shift ;;
        --channels) SHOW_CHANNELS=true; shift ;;
        --help)
            echo "╔══════════════════════════════════════════╗"
            echo "║     YOUDOWN BRAIN — Multi-Agent System   ║"
            echo "╠══════════════════════════════════════════╣"
            echo "║ Roller:                                  ║"
            echo "║   ece     : Bas Mimar (plan olusturur)   ║"
            echo "║   ceylin  : Orkestrator (dagitir)        ║"
            echo "║   ismail  : Senior Developer             ║"
            echo "║   zeynep  : UX Architect                 ║"
            echo "║   hasan   : Backend Architect            ║"
            echo "║   saki    : Frontend Developer           ║"
            echo "║   ahmet   : Reality Checker / QA         ║"
            echo "║   huseyin : DevOps                       ║"
            echo "╠══════════════════════════════════════════╣"
            echo "║ Modlar:                                  ║"
            echo "║   pipeline : Ece/Ceylin pipeline modu    ║"
            echo "║   worker   : Developer/DevOps is modu    ║"
            echo "║   qa       : QA test modu                ║"
            echo "║   collab   : Serbest isbirligi           ║"
            echo "╠══════════════════════════════════════════╣"
            echo "║ Durum:                                   ║"
            echo "║   --status   : Pipeline durumu           ║"
            echo "║   --channels : Kanal mesaj sayilari      ║"
            echo "╚══════════════════════════════════════════╝"
            exit 0 ;;
        *) shift ;;
    esac
done

# === Status ===
if $SHOW_STATUS; then
    if [[ -f "$STATUS_FILE" ]]; then
        pipeline_summary
        echo ""
        handoff_history
    else
        echo "Henuz gorev yok. 'start_task.sh' ile baslat."
    fi
    exit 0
fi

# === Channel stats ===
if $SHOW_CHANNELS; then
    echo ""
    echo "KANAL DURUMLARI"
    echo "─────────────────────"
    channel_stats
    echo "─────────────────────"
    exit 0
fi

# === Validasyon ===
[[ -z "$MY_ROLE" ]] && echo "Hata: --role gerekli. Kullanim: $0 --help" && exit 1
echo "$ALL_ROLES" | grep -qw "$MY_ROLE" || { echo "Hata: Gecersiz rol '$MY_ROLE'. Gecerli: $ALL_ROLES"; exit 1; }
[[ ! -x "$CLAUDE" ]] && echo "Hata: Claude bulunamadi: $CLAUDE" && exit 1

# === Kanal tespiti ===
MY_CHANNEL=$(get_agent_team "$MY_ROLE")
ACTIVE_CHANNEL="$MY_CHANNEL"

log "$MY_ROLE" "Baslatildi: rol=$MY_ROLE, mod=$MODE, kanal=$MY_CHANNEL"

# === Yardimci: proje dosyalarini oku ===
read_project_files() {
    local root="$1" max_chars="${2:-15000}"
    local output=""
    local project_type="generic"
    [ -f "$root/package.json" ] && project_type="react"
    [ -f "$root/Package.swift" ] && project_type="swift"

    if [ "$project_type" = "react" ]; then
        for f in $(find "$root/src" -maxdepth 3 -type f \( -name "*.jsx" -o -name "*.js" -o -name "*.tsx" -o -name "*.ts" -o -name "*.css" \) 2>/dev/null | head -20); do
            local rel=${f#$root/}
            local content=$(head -100 "$f" 2>/dev/null || true)
            output+="=== $rel ===
$content

"
            [ ${#output} -gt "$max_chars" ] && break
        done
    elif [ "$project_type" = "swift" ]; then
        for f in $(find "$root" -maxdepth 4 -type f -name "*.swift" 2>/dev/null | head -20); do
            local rel=${f#$root/}
            local content=$(head -100 "$f" 2>/dev/null || true)
            output+="=== $rel ===
$content

"
            [ ${#output} -gt "$max_chars" ] && break
        done
    fi
    printf '%s' "$output"
    return 0
}

# === Dosya agaci ===
get_file_tree() {
    local root="$1"
    if [ -f "$root/package.json" ]; then
        find "$root/src" -maxdepth 3 -type f 2>/dev/null | head -30 | sed "s|$root/||"
    elif [ -f "$root/Package.swift" ] && [ -d "$root/Sources" ]; then
        find "$root/Sources" -maxdepth 3 -type f 2>/dev/null | head -30 | sed "s|$root/||"
    else
        find "$root" -maxdepth 2 -type f -not -path '*/\.*' -not -path '*/node_modules/*' 2>/dev/null | head -30 | sed "s|$root/||"
    fi
    return 0
}

# ╔══════════════════════════════════════════╗
# ║           MOD: PIPELINE (Ece)           ║
# ╚══════════════════════════════════════════╝
run_pipeline_ece() {
    log "ECE" "Pipeline modu — plan olusturma basliyor"

    # Gorev mesajini oku (genel kanaldan veya task_status'tan)
    local task=""
    if [ -f "$STATUS_FILE" ]; then
        task=$(_SF="$STATUS_FILE" python3 -c "import json,os; print(json.load(open(os.environ['_SF'])).get('task',''))" 2>/dev/null || true)
    fi
    if [ -z "$task" ]; then
        local last_file=$(get_last_file "genel")
        if [ -n "$last_file" ]; then
            task=$(_LF="$last_file" python3 -c "import json,os; print(json.load(open(os.environ['_LF']))['content'])" 2>/dev/null || true)
        fi
    fi
    [ -z "$task" ] && log "ECE" "Gorev bulunamadi. start_task.sh ile baslat." && return 1

    # Proje analizi
    local file_tree=$(get_file_tree "$PROJECT_ROOT")
    local project_files=$(read_project_files "$PROJECT_ROOT" 10000)

    # Plan olustur
    local plan_prompt="GOREV: $task

PROJE DOSYALARI:
$file_tree

MEVCUT KOD:
$project_files

EKIPLER:
- Tasarim: Ismail (Senior Dev) + Zeynep (UX Architect) — kanal: tasarim
- Backend: Hasan (Backend Architect) + Saki (Frontend Dev) — kanal: backend
- QA/DevOps: Ahmet (Reality Checker) + Huseyin (DevOps) — kanal: qa

TALIMAT: Bu gorevi analiz et ve bir plan olustur. Ciktini SADECE asagidaki JSON formatinda ver, baska bir sey yazma:

{
  \"task\": \"gorev aciklamasi\",
  \"architecture\": \"teknik mimari ozeti\",
  \"steps\": [
    {
      \"id\": 1,
      \"desc\": \"adim aciklamasi\",
      \"assignee\": \"ajan_adi\",
      \"team\": \"ekip_kanali\",
      \"depends_on\": [],
      \"acceptance_criteria\": [\"kriter1\", \"kriter2\"]
    }
  ]
}

KURALLAR:
- Her adim tek bir ajanin yapabilecegi buyuklukte olsun
- Bagimliliklari dogru isaretle
- Kabul kriterlerini net ve test edilebilir yaz
- assignee: ismail, zeynep, hasan, saki, ahmet, huseyin
- team: tasarim, backend, qa
- Paralel calisabilecekleri ayni depends_on ile isaretleme"

    log "ECE" "Plan icin Claude cagriliyor..."
    local plan_reply=$(call_claude "ece" "$plan_prompt")

    if [ -z "$plan_reply" ]; then
        log "ECE" "HATA: Plan olusturulamadi"
        return 1
    fi

    # JSON'u cikart (bazen markdown code block icinde geliyor)
    local plan_json=$(echo "$plan_reply" | python3 -c "
import sys, json, re
text = sys.stdin.read()
# Markdown code block icindeyse cikar
match = re.search(r'\`\`\`(?:json)?\s*(\{.*?\})\s*\`\`\`', text, re.DOTALL)
if match:
    text = match.group(1)
else:
    # Ilk { ile son } arasini al
    start = text.find('{')
    end = text.rfind('}')
    if start >= 0 and end > start:
        text = text[start:end+1]
# Validate
try:
    data = json.loads(text)
    print(json.dumps(data, ensure_ascii=False, indent=2))
except:
    print(text)
" 2>/dev/null)

    # Pipeline'i baslat
    init_pipeline "$plan_json"
    log "ECE" "Plan olusturuldu ve pipeline baslatildi"

    # Plani genel kanala gonder (Ceylin okusun)
    send_msg "ece" "PLAN HAZIR. Pipeline baslatildi. Plan:
$plan_json" "genel"

    pipeline_summary
}

# ╔══════════════════════════════════════════╗
# ║        MOD: PIPELINE (Ceylin)           ║
# ╚══════════════════════════════════════════╝
run_pipeline_ceylin() {
    log "CEYLİN" "Orkestrasyon modu — gorev dagitimi basliyor"

    [ ! -f "$STATUS_FILE" ] && log "CEYLİN" "task_status.json yok. Ece henuz plan olusturmamis." && return 1

    local phase=$(_SF="$STATUS_FILE" python3 -c "import json,os; print(json.load(open(os.environ['_SF'])).get('phase',''))" 2>/dev/null)
    [ "$phase" = "done" ] && log "CEYLİN" "Pipeline tamamlanmis!" && pipeline_summary && return 0

    # Gorev dagitim dongusu
    while true; do
        local next_task=$(get_next_task)

        if [ "$next_task" = "NONE" ]; then
            # Devam eden gorev var mi kontrol et
            local in_progress=$(_SF="$STATUS_FILE" python3 -c "
import json, os
data = json.load(open(os.environ['_SF']))
active = [s for s in data['steps'] if s['status'] == 'in_progress']
print(len(active))
" 2>/dev/null)

            if [ "$in_progress" = "0" ]; then
                # Tum adimlar tamamlandi veya basarisiz
                local done_count=$(_SF="$STATUS_FILE" python3 -c "import json,os; data=json.load(open(os.environ['_SF'])); print(data['steps_done'])" 2>/dev/null)
                local total_count=$(_SF="$STATUS_FILE" python3 -c "import json,os; data=json.load(open(os.environ['_SF'])); print(data['steps_total'])" 2>/dev/null)

                if [ "$done_count" = "$total_count" ]; then
                    log "CEYLİN" "TUM GOREVLER TAMAMLANDI!"
                    update_pipeline_status "phase" "done"
                    pipeline_summary
                    send_msg "ceylin" "PIPELINE TAMAMLANDI! Tum gorevler basariyla tamamlandi." "genel"
                    return 0
                else
                    log "CEYLİN" "Bazi gorevler basarisiz. Ece'ye eskalasyon gerekli."
                    pipeline_summary
                    return 1
                fi
            fi

            log "CEYLİN" "Gorev bekleniyor... (aktif: $in_progress)"
            sleep "$POLL"
            continue
        fi

        # Gorevi ata
        assign_task "$next_task"

        local task_id=$(echo "$next_task" | python3 -c "import json,sys; print(json.load(sys.stdin)['id'])")
        local assignee=$(echo "$next_task" | python3 -c "import json,sys; print(json.load(sys.stdin)['assignee'])")
        local team=$(echo "$next_task" | python3 -c "import json,sys; print(json.load(sys.stdin)['team'])")
        local desc=$(echo "$next_task" | python3 -c "import json,sys; print(json.load(sys.stdin)['desc'])")
        local criteria=$(echo "$next_task" | python3 -c "import json,sys; print(json.dumps(json.load(sys.stdin).get('acceptance_criteria',[])))")

        # Worker'i calistir (ayni process icinde)
        log "CEYLİN" "Worker baslatiliyor: $assignee (gorev #$task_id)"
        run_worker_task "$assignee" "$task_id" "$desc" "$criteria" "$team"

        # QA'ya gonder
        local worker_output=$(get_context 5000 "$team" | tail -20)
        log "CEYLİN" "Gorev #$task_id QA'ya gonderiliyor..."

        local qa_result=$(run_qa_check "$task_id" "$PROJECT_ROOT")
        local verdict=$(echo "$qa_result" | head -1)
        local qa_details=$(echo "$qa_result" | sed '1,/---QA_DETAILS---/d')

        process_qa_result "$task_id" "$verdict" "$qa_details"
        local qa_exit=$?

        if [ $qa_exit -eq 1 ]; then
            # FAIL — retry gerekli, tekrar worker calistir
            log "CEYLİN" "Gorev #$task_id QA basarisiz, retry..."
            # Retry dongusu
            local max_retry=2  # 2 ek deneme (toplam 3)
            for retry_i in $(seq 1 $max_retry); do
                run_worker_task "$assignee" "$task_id" "$desc (DUZELTME: $qa_details)" "$criteria" "$team"
                qa_result=$(run_qa_check "$task_id" "$PROJECT_ROOT")
                verdict=$(echo "$qa_result" | head -1)
                qa_details=$(echo "$qa_result" | sed '1,/---QA_DETAILS---/d')
                process_qa_result "$task_id" "$verdict" "$qa_details"
                qa_exit=$?
                [ $qa_exit -eq 0 ] && break  # PASS
                [ $qa_exit -eq 2 ] && break  # Escalation
            done
        fi

        pipeline_summary
        sleep 1
    done
}

# ╔══════════════════════════════════════════╗
# ║           MOD: WORKER                    ║
# ╚══════════════════════════════════════════╝
run_worker_task() {
    local worker_role="$1" task_id="$2" task_desc="$3" criteria="$4" team="$5"

    log "$worker_role" "Gorev #$task_id basliyor: $task_desc"

    # Proje dosyalarini oku
    local project_files=$(read_project_files "$PROJECT_ROOT" 10000)
    local file_tree=$(get_file_tree "$PROJECT_ROOT")

    # Worker'a prompt hazirla
    local worker_prompt="GOREV #$task_id: $task_desc

KABUL KRITERLERI: $criteria

PROJE KLASORU: $PROJECT_ROOT
PROJE DOSYA AGACI:
$file_tree

MEVCUT KOD:
$project_files

TALIMAT: Bu gorevi tamamla. Kod degisiklikleri gerekiyorsa, her dosya icin asagidaki formati kullan:

===FILE: dosya/yolu===
dosya icerigi buraya
===END===

KURALLAR:
- Sadece verilen gorevi yap, ekstra ozellik ekleme
- Tum kabul kriterlerini karsilaadindan emin ol
- Guvenlik acigi birakma
- Build kirilmasin"

    # Claude'u cagir
    local reply=$(call_claude "$worker_role" "$worker_prompt")

    if [ -z "$reply" ]; then
        log "$worker_role" "HATA: Claude cevap vermedi"
        send_msg "$worker_role" "HATA: Gorev #$task_id icin cevap alinamadi" "$team"
        return 1
    fi

    # Dosya ciktilarini uygula
    apply_code_changes "$reply" "$PROJECT_ROOT"

    # Sonucu kanala bildir
    send_msg "$worker_role" "TAMAMLANDI: Gorev #$task_id
$reply" "$team"

    log "$worker_role" "Gorev #$task_id tamamlandi"
    return 0
}

# === Kod degisikliklerini uygula ===
apply_code_changes() {
    local reply="$1" root="$2"

    export _PROJECT_ROOT="$root"
    echo "$reply" | python3 -c "
import sys, os, re

text = sys.stdin.read()
root = os.path.realpath(os.environ['_PROJECT_ROOT'])

# ===FILE: path=== ... ===END=== bloklarini bul
pattern = r'===FILE:\s*(.+?)===\s*\n(.*?)===END==='
matches = re.findall(pattern, text, re.DOTALL)

for filepath, content in matches:
    filepath = filepath.strip()
    # Goreli yolu mutlak yap
    if not filepath.startswith('/'):
        full_path = os.path.join(root, filepath)
    else:
        full_path = filepath

    # GUVENLIK: path proje kokunun disina cikamasin
    full_path = os.path.realpath(full_path)
    if not full_path.startswith(root + '/') and full_path != root:
        print(f'  REDDEDILDI (proje disi): {filepath}')
        continue

    # Klasoru olustur
    os.makedirs(os.path.dirname(full_path), exist_ok=True)

    # Dosyayi yaz
    with open(full_path, 'w') as f:
        f.write(content.strip() + '\n')
    print(f'  Yazildi: {filepath}')
" 2>/dev/null || true
}

# ╔══════════════════════════════════════════╗
# ║         MOD: WORKER DAEMON               ║
# ╚══════════════════════════════════════════╝
run_worker_daemon() {
    log "$MY_ROLE" "Worker daemon baslatildi — kanal: $MY_CHANNEL"

    while true; do
        touch_heartbeat "$MY_ROLE"

        # Kanalda yeni handoff var mi?
        if is_my_turn "$MY_ROLE" "$MY_CHANNEL"; then
            local last_file=$(get_last_file "$MY_CHANNEL")
            if [ -n "$last_file" ]; then
                local content=$(_LF="$last_file" python3 -c "import json,os; print(json.load(open(os.environ['_LF']))['content'])" 2>/dev/null || true)

                # HANDOFF mesaji mi?
                if echo "$content" | grep -q "HANDOFF"; then
                    log "$MY_ROLE" "Yeni gorev alindi"

                    local task_desc="$content"
                    local criteria="[]"

                    # Context'ten gorev bilgisini cikar
                    run_worker_task "$MY_ROLE" "0" "$task_desc" "$criteria" "$MY_CHANNEL"
                fi
            fi
        fi

        sleep "$POLL"
    done
}

# ╔══════════════════════════════════════════╗
# ║           MOD: QA DAEMON                 ║
# ╚══════════════════════════════════════════╝
run_qa_daemon() {
    log "AHMET" "QA daemon baslatildi — qa kanalini dinliyor"

    while true; do
        touch_heartbeat "ahmet"

        if is_my_turn "ahmet" "qa"; then
            local last_file=$(get_last_file "qa")
            if [ -n "$last_file" ]; then
                local content=$(_LF="$last_file" python3 -c "import json,os; print(json.load(open(os.environ['_LF']))['content'])" 2>/dev/null || true)

                if echo "$content" | grep -q "QA TALEBI"; then
                    log "AHMET" "Yeni QA talebi alindi"

                    # task_id'yi cikar
                    local task_id=$(echo "$content" | grep -o '#[0-9]*' | head -1 | tr -d '#')
                    [ -z "$task_id" ] && task_id=0

                    local qa_result=$(run_qa_check "$task_id" "$PROJECT_ROOT")
                    local verdict=$(echo "$qa_result" | head -1)
                    local qa_details=$(echo "$qa_result" | sed '1,/---QA_DETAILS---/d')

                    send_msg "ahmet" "QA SONUCU: Gorev #$task_id → $verdict
$qa_details" "qa"
                fi
            fi
        fi

        sleep "$POLL"
    done
}

# ╔══════════════════════════════════════════╗
# ║           MOD: COLLAB                    ║
# ╚══════════════════════════════════════════╝
run_collab() {
    log "$MY_ROLE" "Collab modu — kanal: $MY_CHANNEL"

    local idle=0
    while true; do
        touch_heartbeat "$MY_ROLE"

        if is_my_turn "$MY_ROLE" "$MY_CHANNEL"; then
            idle=0
            local context=$(get_context "$CONTEXT_SIZE" "$MY_CHANNEL")
            local project_files=$(read_project_files "$PROJECT_ROOT" 10000)

            local prompt="KONUSMA GECMISI:
$context

PROJE DOSYALARI:
$project_files

Cevabini yaz. Kod degisikligi gerekiyorsa ===FILE: yol=== formatini kullan."

            local reply=$(call_claude "$MY_ROLE" "$prompt")

            if [ -n "$reply" ]; then
                apply_code_changes "$reply" "$PROJECT_ROOT"
                send_msg "$MY_ROLE" "$reply" "$MY_CHANNEL"
            fi
        else
            idle=$((idle + POLL))
            [ $idle -ge $MAX_IDLE ] && log "$MY_ROLE" "Max idle asildi, cikiliyor." && break
        fi

        sleep "$POLL"
    done
}

# ╔══════════════════════════════════════════╗
# ║              ANA CALISTIRICI             ║
# ╚══════════════════════════════════════════╝

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║     YOUDOWN BRAIN — Multi-Agent v2       ║"
echo "╠══════════════════════════════════════════╣"
echo "  Rol    : $MY_ROLE"
echo "  Mod    : $MODE"
echo "  Kanal  : $MY_CHANNEL"
echo "  Proje  : $PROJECT_ROOT"
echo "  Model  : $MODEL"
echo "╚══════════════════════════════════════════╝"
echo ""

case "$MODE" in
    pipeline)
        if [ "$MY_ROLE" = "ece" ]; then
            run_pipeline_ece
        elif [ "$MY_ROLE" = "ceylin" ]; then
            run_pipeline_ceylin
        else
            echo "Hata: pipeline modu sadece ece ve ceylin icin."
            exit 1
        fi
        ;;
    worker)
        if [ "$MY_ROLE" = "ahmet" ]; then
            echo "Ahmet icin --mode qa kullanin."
            exit 1
        fi
        run_worker_daemon
        ;;
    qa)
        if [ "$MY_ROLE" != "ahmet" ]; then
            echo "QA modu sadece ahmet icin."
            exit 1
        fi
        run_qa_daemon
        ;;
    collab)
        run_collab
        ;;
    *)
        echo "Hata: Gecersiz mod '$MODE'. Gecerli: pipeline, worker, qa, collab"
        exit 1
        ;;
esac
