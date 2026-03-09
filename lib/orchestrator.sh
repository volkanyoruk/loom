#!/bin/bash
# lib/orchestrator.sh — Ceylin'in gorev dagitim ve takip motoru
# Ece'nin planini alir, ekiplere dagitir, Dev↔QA dongusunu yonetir

# AGENTS_DIR ve protocol.sh zaten youdown-brain.sh tarafindan yuklenmis olmali
AGENTS_DIR="${AGENTS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
STATUS_FILE="${STATUS_FILE:-$AGENTS_DIR/task_status.json}"
QA_MAX_RETRY=3

# === Plani task_status.json'a yaz ===
init_pipeline() {
    local plan_json="$1"
    printf '%s' "$plan_json" | _SF="$STATUS_FILE" python3 -c "
import json, sys, os
from datetime import datetime, timezone

plan = json.loads(sys.stdin.read())
steps = []
for s in plan.get('steps', []):
    steps.append({
        'id': s['id'],
        'desc': s['desc'],
        'assignee': s.get('assignee', 'ismail'),
        'team': s.get('team', 'tasarim'),
        'depends_on': s.get('depends_on', []),
        'acceptance_criteria': s.get('acceptance_criteria', []),
        'status': 'pending',
        'retry_count': 0,
        'qa_verdict': None,
        'error_summary': None
    })

data = {
    'task_id': plan.get('task_id', 'auto'),
    'task': plan.get('task', ''),
    'architecture': plan.get('architecture', ''),
    'phase': 'implementation',
    'created_at': datetime.now(timezone.utc).isoformat(),
    'updated_at': datetime.now(timezone.utc).isoformat(),
    'steps': steps,
    'steps_total': len(steps),
    'steps_done': 0,
    'current_step_id': steps[0]['id'] if steps else 0,
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
json.dump(data, open(os.environ['_SF'], 'w'), ensure_ascii=False, indent=2)
print(f'Pipeline baslatildi: {len(steps)} adim')
"
}

# === Siradaki gorevi bul ===
get_next_task() {
    _SF="$STATUS_FILE" python3 -c "
import json, os
data = json.load(open(os.environ['_SF']))
for s in data['steps']:
    # Bagimliliklari kontrol et
    deps_done = all(
        any(d['id'] == dep and d['status'] == 'done' for d in data['steps'])
        for dep in s.get('depends_on', [])
    )
    if s['status'] == 'pending' and deps_done:
        print(json.dumps(s))
        exit(0)
print('NONE')
" 2>/dev/null || echo "NONE"
}

# === Paralel calisabilecek gorevleri bul ===
get_parallel_tasks() {
    _SF="$STATUS_FILE" python3 -c "
import json, os
data = json.load(open(os.environ['_SF']))
parallel = []
for s in data['steps']:
    deps_done = all(
        any(d['id'] == dep and d['status'] == 'done' for d in data['steps'])
        for dep in s.get('depends_on', [])
    )
    if s['status'] == 'pending' and deps_done:
        parallel.append(s)
print(json.dumps(parallel))
" 2>/dev/null || echo "[]"
}

# === Gorev durumunu guncelle ===
update_task_status() {
    local task_id="$1" field="$2" value="$3"
    printf '%s\n%s\n%s' "$task_id" "$field" "$value" | _SF="$STATUS_FILE" python3 -c "
import json, sys, os
from datetime import datetime, timezone

sf = os.environ['_SF']
lines = sys.stdin.read().split('\n', 2)
task_id = int(lines[0])
field = lines[1]
value = lines[2]

try:
    value = int(value)
except ValueError:
    if value == 'None':
        value = None

data = json.load(open(sf))
for s in data['steps']:
    if s['id'] == task_id:
        s[field] = value
        break
data['steps_done'] = sum(1 for s in data['steps'] if s['status'] == 'done')
data['updated_at'] = datetime.now(timezone.utc).isoformat()
if data['steps_done'] == data['steps_total'] and data['steps_total'] > 0:
    data['phase'] = 'done'
json.dump(data, open(sf, 'w'), ensure_ascii=False, indent=2)
" || true
}

# === Gorevi ekibe ata (handoff olustur + kanal mesaji) ===
assign_task() {
    local task_json="$1"
    # Tek python cagrisi ile tum alanlari cikar
    local parsed
    parsed=$(echo "$task_json" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(d.get('id', 0))
print(d.get('assignee', 'ismail'))
print(d.get('team', 'tasarim'))
print(d.get('desc', ''))
print(json.dumps(d.get('acceptance_criteria', [])))
" 2>/dev/null) || { log "CEYLİN" "HATA: task JSON parse edilemedi"; return 1; }

    local task_id assignee team desc criteria
    task_id=$(echo "$parsed" | sed -n '1p')
    assignee=$(echo "$parsed" | sed -n '2p')
    team=$(echo "$parsed" | sed -n '3p')
    desc=$(echo "$parsed" | sed -n '4p')
    criteria=$(echo "$parsed" | sed -n '5p')

    # Gorev durumunu in_progress yap
    update_task_status "$task_id" "status" "in_progress"

    # Pipeline context'ini al
    local pipeline_context
    pipeline_context=$(cat "$STATUS_FILE")

    # Handoff olustur
    create_handoff "ceylin" "$assignee" "$task_id" "$desc" "$pipeline_context"

    log "CEYLİN" "Gorev #$task_id → $assignee ($team ekibi)"
}

# === QA'ya gonder ===
send_to_qa() {
    local task_id="$1" developer="$2" output="$3"
    local parsed
    parsed=$(_SF="$STATUS_FILE" python3 -c "
import json, sys, os
data = json.load(open(os.environ['_SF']))
tid = int(sys.argv[1])
for s in data['steps']:
    if s['id'] == tid:
        print(s['desc'])
        print(json.dumps(s.get('acceptance_criteria',[])))
        print(s.get('retry_count', 0) + 1)
        break
" "$task_id" 2>/dev/null) || true
    local task_desc criteria attempt
    task_desc=$(echo "$parsed" | sed -n '1p')
    criteria=$(echo "$parsed" | sed -n '2p')
    attempt=$(echo "$parsed" | sed -n '3p')

    send_msg "ceylin" "QA TALEBI: Gorev #$task_id
Developer: $developer
Aciklama: $task_desc
Kabul Kriterleri: $criteria
Deneme: $attempt/$QA_MAX_RETRY
Developer Ciktisi: $output" "qa"

    log "CEYLİN" "Gorev #$task_id QA'ya gonderildi (deneme $attempt/$QA_MAX_RETRY)"
}

# === QA Sonucunu isle ===
process_qa_result() {
    local task_id="$1" verdict="$2" feedback="$3"

    if [ "$verdict" = "PASS" ]; then
        update_task_status "$task_id" "status" "done"
        update_task_status "$task_id" "qa_verdict" "PASS"
        log "CEYLİN" "Gorev #$task_id QA GECTI ✅"
        return 0
    fi

    # FAIL — retry kontrolu
    local current_retry
    current_retry=$(_SF="$STATUS_FILE" python3 -c "
import json, sys, os
data = json.load(open(os.environ['_SF']))
tid = int(sys.argv[1])
for s in data['steps']:
    if s['id'] == tid:
        print(s.get('retry_count', 0))
        break
" "$task_id" 2>/dev/null) || current_retry=0

    local new_retry=$((current_retry + 1))
    update_task_status "$task_id" "retry_count" "$new_retry"

    if [ "$new_retry" -ge "$QA_MAX_RETRY" ]; then
        # Eskalasyon
        update_task_status "$task_id" "status" "failed"
        update_task_status "$task_id" "error_summary" "QA 3 denemede gecemedi"
        send_msg "ceylin" "ESKALASYON: Gorev #$task_id $QA_MAX_RETRY denemede QA gecemedi.
Son geri bildirim: $feedback
Karar gerekli: yeniden ata / bolerle / ertele / kabul et" "genel"
        log "CEYLİN" "Gorev #$task_id ESKALE EDILDI ❌ (${new_retry} deneme)"
        return 2
    fi

    # Developer'a geri gonder
    local assignee
    assignee=$(_SF="$STATUS_FILE" python3 -c "
import json, sys, os
data = json.load(open(os.environ['_SF']))
tid = int(sys.argv[1])
for s in data['steps']:
    if s['id'] == tid:
        print(s['assignee'])
        break
" "$task_id" 2>/dev/null) || assignee="ismail"
    local team=$(get_agent_team "$assignee")
    update_task_status "$task_id" "status" "in_progress"

    send_msg "ceylin" "DUZELTME TALEBI: Gorev #$task_id (deneme $new_retry/$QA_MAX_RETRY)
QA Geri Bildirimi: $feedback
SADECE belirtilen sorunlari duzelt, yeni ozellik ekleme." "$team"

    log "CEYLİN" "Gorev #$task_id developer'a geri gonderildi (deneme $new_retry/$QA_MAX_RETRY)"
    return 1
}

# === Pipeline Ozeti ===
pipeline_summary() {
    _SF="$STATUS_FILE" python3 -c "
import json, os
data = json.load(open(os.environ['_SF']))
total = data['steps_total']
done = data['steps_done']
phase = data['phase']
pct = int(done / total * 100) if total > 0 else 0

print(f'''
╔══════════════════════════════════════════╗
║       PIPELINE DURUM RAPORU             ║
╠══════════════════════════════════════════╣
  Gorev  : {data.get('task', '—')}
  Faz    : {phase}
  Ilerleme: {done}/{total} (%{pct})
╠══════════════════════════════════════════╣''')

icons = {'pending': '⏳', 'in_progress': '🔄', 'done': '✅', 'failed': '❌', 'skipped': '⏭'}
for s in data['steps']:
    icon = icons.get(s['status'], '?')
    retry = f' (retry:{s[\"retry_count\"]})' if s.get('retry_count', 0) > 0 else ''
    qa = f' [QA:{s[\"qa_verdict\"]}]' if s.get('qa_verdict') else ''
    print(f'  {icon} #{s[\"id\"]} {s[\"desc\"]} [{s[\"assignee\"]}]{retry}{qa}')
    if s.get('error_summary'):
        print(f'       ⚠ {s[\"error_summary\"]}')

blockers = data.get('blockers', [])
if blockers:
    print(f'  🚧 Engeller: {\", \".join(blockers)}')

print('╚══════════════════════════════════════════╝')
" 2>/dev/null
}
