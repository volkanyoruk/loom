#!/bin/bash
# Durum paneli — pipeline durumu + komutlar
AGENTS_DIR="$1"
STATUS_FILE="$AGENTS_DIR/task_status.json"

show_status() {
    printf '\033[1;34m━━━ PIPELINE DURUMU (%s) ━━━\033[0m\n\n' "$(date '+%H:%M:%S')"

    if [ -f "$STATUS_FILE" ]; then
        STATUS_FILE="$STATUS_FILE" python3 - <<'PY'
import json, os

path = os.environ['STATUS_FILE']
try:
    d = json.load(open(path))
    phase = d.get('phase', '?')
    task  = d.get('task', '')
    done  = d.get('steps_done', 0)
    total = d.get('steps_total', 0)

    phase_icons = {"planning":"📋","implementation":"⚙️","review":"👁","testing":"🧪","done":"✅","failed":"❌"}
    step_icons = {"pending":"⏳","in_progress":"🔄","done":"✅","failed":"❌","skipped":"⏭"}

    print(f"  Gorev : {task[:60]}")
    print(f"  Faz   : {phase_icons.get(phase,'?')} {phase}")

    if total > 0:
        bar_len = 20
        filled = int(bar_len * done / total)
        bar = '█' * filled + '░' * (bar_len - filled)
        pct = int(done / total * 100)
        print(f"  Adim  : [{bar}] {done}/{total} (%{pct})")
    print()

    for s in d.get('steps', []):
        icon = step_icons.get(s.get('status',''), '?')
        assignee = s.get('assignee', '?')
        team = s.get('team', '?')
        retry = f" (retry:{s['retry_count']})" if s.get('retry_count', 0) > 0 else ""
        qa = f" QA:{s['qa_verdict']}" if s.get('qa_verdict') else ""
        desc = s.get('desc', s.get('title', ''))[:45]
        print(f"  {icon} #{s['id']} {desc}")
        print(f"     [{assignee}/{team}]{retry}{qa}")

    # QA Stats
    qa = d.get('qa_stats', {})
    if qa.get('total_tests', 0) > 0:
        print(f"\n  QA: {qa['total_tests']} test, %{qa.get('first_pass_rate',0)} ilk gecis")

    blockers = d.get('blockers', [])
    if blockers:
        print(f"\n  🚧 Engeller: {', '.join(blockers)}")

except Exception as e:
    print(f"  (okunamadi: {e})")
PY
    else
        echo "  (gorev yok — start_task.sh ile baslat)"
    fi

    echo ""
    printf '\033[1;33m━━━ KOMUTLAR ━━━\033[0m\n'
    echo "  ./start_task.sh \"gorev\" --project /path"
    echo "  ./run_pipeline.sh \"gorev\" --project /path"
    echo "  ./youdown-brain.sh --status"
    echo "  ./youdown-brain.sh --channels"
    echo ""
    echo "  [Ctrl+B 1/2/3] pencere degistir"
    echo "  [Ctrl+B D]     panelden cik"
}

while true; do
    clear
    show_status
    sleep 3
done
