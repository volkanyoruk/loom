#!/bin/bash
# lib/qa_gate.sh — Ahmet'in QA kapisi
# Her gorevi test eder, PASS/FAIL karari verir, kanit ister

# AGENTS_DIR ve protocol.sh zaten youdown-brain.sh tarafindan yuklenmis olmali
AGENTS_DIR="${AGENTS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
STATUS_FILE="${STATUS_FILE:-$AGENTS_DIR/task_status.json}"

# === QA Test Calistir ===
run_qa_check() {
    local task_id="$1" project_root="$2"

    # Gorev bilgilerini al
    local task_info=$(_SF="$STATUS_FILE" _TID="$task_id" python3 -c "
import json, os
data = json.load(open(os.environ['_SF']))
tid = int(os.environ['_TID'])
for s in data['steps']:
    if s['id'] == tid:
        print(json.dumps(s, ensure_ascii=False))
        break
")

    local desc=$(echo "$task_info" | python3 -c "import json,sys; print(json.load(sys.stdin)['desc'])")
    local criteria=$(echo "$task_info" | python3 -c "import json,sys; print(json.dumps(json.load(sys.stdin).get('acceptance_criteria',[])))")
    local attempt=$(echo "$task_info" | python3 -c "import json,sys; print(json.load(sys.stdin).get('retry_count',0) + 1)")

    # Proje tipini tespit et
    local project_type="generic"
    [ -f "$project_root/package.json" ] && project_type="react"
    [ -f "$project_root/Package.swift" ] && project_type="swift"

    # Build testi
    local build_result="skip"
    local build_output=""
    if [ "$project_type" = "react" ]; then
        build_output=$(cd "$project_root" && npm run build 2>&1) && build_result="success" || build_result="failed"
    elif [ "$project_type" = "swift" ]; then
        build_output=$(cd "$project_root" && swift build 2>&1) && build_result="success" || build_result="failed"
    fi

    # Claude'a QA analizi yaptir
    local qa_prompt="Sen Ahmet, Reality Checker / QA ajanisisn.

GOREV #$task_id: $desc
KABUL KRITERLERI: $criteria
DENEME: $attempt/3
BUILD SONUCU: $build_result
BUILD CIKTISI (son 50 satir): $(echo "$build_output" | tail -50)
PROJE TIPI: $project_type

Gorevi test et ve karar ver. Ciktini su formatta ver:

VERDICT: PASS veya FAIL
ISSUES: (varsa sorunlar listesi, yoksa 'yok')
FIX_INSTRUCTIONS: (FAIL ise duzeltme talimatlari)
NOTES: (ek notlar)

ONEMLI: Varsayilan kararin NEEDS WORK. PASS icin tum kriterlerin karsilanmis olmasi gerekir."

    local qa_reply=$(call_claude "ahmet" "$qa_prompt")

    # Verdict'i parse et
    local verdict="FAIL"
    if echo "$qa_reply" | grep -qi "VERDICT.*PASS"; then
        verdict="PASS"
    fi

    # QA verdict dosyasi olustur
    create_qa_verdict "$task_id" "$verdict" "$attempt" "$qa_reply"

    # Sonucu dondur
    echo "$verdict"
    echo "---QA_DETAILS---"
    echo "$qa_reply"
}

# === Toplu QA Raporu ===
qa_summary() {
    _SF="$STATUS_FILE" _HD="$HANDOFFS_DIR" python3 -c "
import json, os

status_file = os.environ['_SF']
handoffs_dir = os.environ['_HD']

data = json.load(open(status_file))
qa_files = sorted([f for f in os.listdir(handoffs_dir) if f.startswith('qa_')])

total_tests = len(qa_files)
passes = sum(1 for f in qa_files if 'PASS' in open(os.path.join(handoffs_dir, f)).read()[:200])
fails = total_tests - passes

print(f'''
QA OZET RAPORU
{'─' * 40}
Toplam test  : {total_tests}
PASS         : {passes}
FAIL         : {fails}
Basari orani : {int(passes/total_tests*100) if total_tests > 0 else 0}%
{'─' * 40}''')

for s in data['steps']:
    icon = '✅' if s.get('qa_verdict') == 'PASS' else '❌' if s.get('qa_verdict') == 'FAIL' else '⏳'
    retry = f' ({s[\"retry_count\"]} retry)' if s.get('retry_count', 0) > 0 else ''
    print(f'  {icon} #{s[\"id\"]} {s[\"desc\"]}{retry}')
" 2>/dev/null
}
