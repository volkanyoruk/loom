#!/bin/bash
# lib/handoff.sh — Ekipler arasi teslim yonetimi
# Handoff olusturma, listeleme, durum guncelleme

# AGENTS_DIR ve protocol.sh zaten youdown-brain.sh tarafindan yuklenmis olmali
AGENTS_DIR="${AGENTS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# === Bekleyen handoff'lari listele ===
list_pending_handoffs() {
    local for_agent="${1:-}"
    python3 -c "
import json, os
handoffs_dir = '$HANDOFFS_DIR'
for f in sorted(os.listdir(handoffs_dir)):
    if not f.endswith('.json') or f.startswith('qa_'):
        continue
    data = json.load(open(os.path.join(handoffs_dir, f)))
    if data.get('status') != 'pending':
        continue
    if '$for_agent' and data.get('to') != '$for_agent':
        continue
    print(f'  📩 #{data[\"task_id\"]} {data[\"from\"]} → {data[\"to\"]}: {data[\"task_desc\"]}')
" 2>/dev/null
}

# === Handoff'u tamamla ===
complete_handoff() {
    local task_id="$1" agent="$2"
    python3 -c "
import json, os
handoffs_dir = '$HANDOFFS_DIR'
for f in sorted(os.listdir(handoffs_dir)):
    if not f.endswith('.json') or f.startswith('qa_'):
        continue
    path = os.path.join(handoffs_dir, f)
    data = json.load(open(path))
    if data.get('task_id') == $task_id and data.get('to') == '$agent':
        data['status'] = 'completed'
        json.dump(data, open(path, 'w'), ensure_ascii=False, indent=2)
        print(f'Handoff tamamlandi: #{data[\"task_id\"]} ({data[\"from\"]} → {data[\"to\"]})')
        break
" 2>/dev/null
}

# === Handoff gecmisini goster ===
handoff_history() {
    python3 -c "
import json, os
from datetime import datetime
handoffs_dir = '$HANDOFFS_DIR'
print(f'\\nHANDOFF GECMISI')
print('─' * 50)
for f in sorted(os.listdir(handoffs_dir)):
    if not f.endswith('.json') or f.startswith('qa_'):
        continue
    data = json.load(open(os.path.join(handoffs_dir, f)))
    status_icon = '✅' if data['status'] == 'completed' else '⏳' if data['status'] == 'pending' else '❌'
    ts = datetime.fromtimestamp(data['timestamp']).strftime('%H:%M:%S')
    print(f'  {status_icon} [{ts}] #{data[\"task_id\"]} {data[\"from\"]} → {data[\"to\"]}: {data[\"task_desc\"][:50]}')
print('─' * 50)
" 2>/dev/null
}
