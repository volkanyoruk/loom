#!/usr/bin/env python3
"""
youdown-brain Web Dashboard
Tarayicida acilan canli pipeline izleme paneli.
Kullanim: python3 dashboard.py [port]
"""

import http.server
import json
import os
import sys
import time
from datetime import datetime
from pathlib import Path

AGENTS_DIR = Path(__file__).parent.resolve()
CHANNELS_DIR = AGENTS_DIR / "channels"
HANDOFFS_DIR = AGENTS_DIR / "handoffs"
STATUS_FILE = AGENTS_DIR / "task_status.json"
LOGS_DIR = AGENTS_DIR / "logs"
PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 7777


def get_pipeline_status():
    if not STATUS_FILE.exists():
        return None
    try:
        return json.loads(STATUS_FILE.read_text())
    except Exception:
        return None


def get_channel_messages():
    channels = {}
    if not CHANNELS_DIR.exists():
        return channels
    for ch_dir in sorted(CHANNELS_DIR.iterdir()):
        if not ch_dir.is_dir() or ch_dir.name.startswith("."):
            continue
        msgs = []
        json_files = sorted(ch_dir.glob("*.json"), key=lambda f: f.name)
        for f in json_files[-20:]:
            try:
                data = json.loads(f.read_text())
                data["_file"] = f.name
                msgs.append(data)
            except Exception:
                continue
        channels[ch_dir.name] = msgs
    return channels


def get_handoffs():
    handoffs = []
    qa_verdicts = []
    if not HANDOFFS_DIR.exists():
        return handoffs, qa_verdicts
    for f in sorted(HANDOFFS_DIR.glob("*.json"), key=lambda f: f.name):
        try:
            data = json.loads(f.read_text())
            data["_file"] = f.name
            if f.name.startswith("qa_"):
                qa_verdicts.append(data)
            else:
                handoffs.append(data)
        except Exception:
            continue
    return handoffs, qa_verdicts


def get_agent_logs(limit=50):
    logs = {}
    if not LOGS_DIR.exists():
        return logs
    for f in sorted(LOGS_DIR.glob("*.log")):
        try:
            lines = f.read_text().strip().split("\n")
            logs[f.stem] = lines[-limit:]
        except Exception:
            continue
    return logs


def get_heartbeats():
    beats = {}
    if not CHANNELS_DIR.exists():
        return beats
    now = time.time()
    for f in CHANNELS_DIR.glob(".heartbeat_*"):
        agent = f.name.replace(".heartbeat_", "")
        mtime = f.stat().st_mtime
        delta = int(now - mtime)
        beats[agent] = {"last_seen": delta, "alive": delta < 120}
    return beats


def build_api_response():
    status = get_pipeline_status()
    channels = get_channel_messages()
    handoffs, qa_verdicts = get_handoffs()
    heartbeats = get_heartbeats()
    logs = get_agent_logs()
    return json.dumps({
        "timestamp": datetime.now().isoformat(),
        "pipeline": status,
        "channels": channels,
        "handoffs": handoffs,
        "qa_verdicts": qa_verdicts,
        "heartbeats": heartbeats,
        "logs": logs,
    }, ensure_ascii=False, default=str)


HTML_PAGE = r"""<!DOCTYPE html>
<html lang="tr">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>youdown-brain Dashboard</title>
<style>
:root {
  --bg: #0d1117;
  --surface: #161b22;
  --border: #30363d;
  --text: #e6edf3;
  --text-dim: #8b949e;
  --accent: #58a6ff;
  --green: #3fb950;
  --red: #f85149;
  --orange: #d29922;
  --purple: #bc8cff;
  --cyan: #39d2c0;
  --pink: #f778ba;
}
* { margin: 0; padding: 0; box-sizing: border-box; }
body {
  background: var(--bg);
  color: var(--text);
  font-family: 'SF Mono', 'Fira Code', 'JetBrains Mono', monospace;
  font-size: 13px;
  line-height: 1.5;
  padding: 16px;
}
h1 {
  font-size: 20px;
  font-weight: 700;
  margin-bottom: 4px;
  color: var(--accent);
}
.header {
  display: flex;
  justify-content: space-between;
  align-items: center;
  margin-bottom: 16px;
  padding-bottom: 12px;
  border-bottom: 1px solid var(--border);
}
.header-right {
  display: flex;
  align-items: center;
  gap: 16px;
  font-size: 12px;
  color: var(--text-dim);
}
.live-dot {
  width: 8px; height: 8px;
  background: var(--green);
  border-radius: 50%;
  display: inline-block;
  animation: pulse 2s infinite;
}
@keyframes pulse {
  0%, 100% { opacity: 1; }
  50% { opacity: 0.3; }
}

/* Grid Layout */
.grid {
  display: grid;
  grid-template-columns: 340px 1fr 300px;
  grid-template-rows: auto 1fr;
  gap: 12px;
  height: calc(100vh - 80px);
}
.panel {
  background: var(--surface);
  border: 1px solid var(--border);
  border-radius: 8px;
  overflow: hidden;
  display: flex;
  flex-direction: column;
}
.panel-title {
  padding: 10px 14px;
  font-size: 12px;
  font-weight: 600;
  text-transform: uppercase;
  letter-spacing: 0.5px;
  border-bottom: 1px solid var(--border);
  display: flex;
  justify-content: space-between;
  align-items: center;
  flex-shrink: 0;
}
.panel-body {
  padding: 10px 14px;
  overflow-y: auto;
  flex: 1;
}

/* Pipeline Status */
.pipeline-panel { grid-column: 1; grid-row: 1; }
.pipeline-panel .panel-title { color: var(--cyan); border-bottom-color: var(--cyan); }
.task-name { font-size: 14px; font-weight: 600; margin-bottom: 8px; }
.phase-badge {
  display: inline-block;
  padding: 2px 8px;
  border-radius: 12px;
  font-size: 11px;
  font-weight: 600;
}
.phase-planning { background: #1f2937; color: var(--accent); }
.phase-implementation { background: #1c2333; color: var(--orange); }
.phase-done { background: #0d2818; color: var(--green); }
.phase-failed { background: #2d1215; color: var(--red); }

.progress-bar {
  width: 100%;
  height: 6px;
  background: var(--border);
  border-radius: 3px;
  margin: 10px 0;
  overflow: hidden;
}
.progress-fill {
  height: 100%;
  border-radius: 3px;
  transition: width 0.5s ease;
}
.progress-fill.green { background: var(--green); }
.progress-fill.orange { background: var(--orange); }
.progress-fill.red { background: var(--red); }

.step-list { list-style: none; }
.step-item {
  padding: 6px 0;
  border-bottom: 1px solid var(--border);
  display: flex;
  align-items: center;
  gap: 8px;
}
.step-item:last-child { border-bottom: none; }
.step-icon { font-size: 14px; flex-shrink: 0; }
.step-id { color: var(--text-dim); font-size: 11px; min-width: 24px; }
.step-desc { flex: 1; }
.step-assignee {
  font-size: 11px;
  padding: 1px 6px;
  border-radius: 4px;
  background: #1c2333;
  color: var(--purple);
}
.step-retry {
  font-size: 10px;
  color: var(--orange);
}

/* Channels */
.channels-panel { grid-column: 2; grid-row: 1 / 3; }
.channels-panel .panel-title { color: var(--accent); border-bottom-color: var(--accent); }

.channel-section { margin-bottom: 16px; }
.channel-header {
  font-size: 12px;
  font-weight: 600;
  padding: 4px 8px;
  border-radius: 4px;
  margin-bottom: 6px;
  display: flex;
  justify-content: space-between;
}
.ch-genel .channel-header { background: #0d2847; color: var(--accent); }
.ch-tasarim .channel-header { background: #0d2818; color: var(--green); }
.ch-backend .channel-header { background: #2a1f00; color: var(--orange); }
.ch-qa .channel-header { background: #2d1215; color: var(--red); }
.ch-broadcast .channel-header { background: #1f0d2e; color: var(--purple); }

.msg {
  padding: 4px 0 4px 12px;
  border-left: 2px solid var(--border);
  margin-bottom: 4px;
  font-size: 12px;
}
.msg-from {
  font-weight: 600;
  margin-right: 6px;
}
.msg-time {
  color: var(--text-dim);
  font-size: 10px;
  margin-left: 4px;
}
.msg-content {
  color: var(--text);
  word-break: break-word;
}
.msg-from.ece { color: var(--cyan); }
.msg-from.ceylin { color: var(--pink); }
.msg-from.ismail { color: var(--green); }
.msg-from.zeynep { color: var(--purple); }
.msg-from.hasan { color: var(--orange); }
.msg-from.saki { color: #7ee787; }
.msg-from.ahmet { color: var(--red); }
.msg-from.huseyin { color: #79c0ff; }
.msg-from.system { color: var(--text-dim); }

/* Handoffs & Agents */
.right-col { grid-column: 3; grid-row: 1 / 3; display: flex; flex-direction: column; gap: 12px; }

.agents-panel .panel-title { color: var(--green); border-bottom-color: var(--green); }
.handoffs-panel .panel-title { color: var(--orange); border-bottom-color: var(--orange); }
.logs-panel .panel-title { color: var(--text-dim); border-bottom-color: var(--text-dim); }

.agent-row {
  display: flex;
  align-items: center;
  gap: 8px;
  padding: 5px 0;
  border-bottom: 1px solid var(--border);
}
.agent-row:last-child { border-bottom: none; }
.agent-dot {
  width: 8px; height: 8px;
  border-radius: 50%;
  flex-shrink: 0;
}
.agent-dot.alive { background: var(--green); }
.agent-dot.dead { background: var(--red); }
.agent-dot.unknown { background: var(--text-dim); }
.agent-name { font-weight: 600; min-width: 70px; }
.agent-status { font-size: 11px; color: var(--text-dim); }

.handoff-item {
  padding: 6px 0;
  border-bottom: 1px solid var(--border);
  font-size: 12px;
}
.handoff-item:last-child { border-bottom: none; }
.handoff-arrow { color: var(--text-dim); }
.verdict-pass { color: var(--green); font-weight: 600; }
.verdict-fail { color: var(--red); font-weight: 600; }

.log-line {
  font-size: 11px;
  color: var(--text-dim);
  padding: 1px 0;
  white-space: nowrap;
  overflow: hidden;
  text-overflow: ellipsis;
}

/* Bottom panel */
.bottom-panel { grid-column: 1; grid-row: 2; }
.bottom-panel .panel-title { color: var(--purple); border-bottom-color: var(--purple); }

/* No data */
.no-data {
  color: var(--text-dim);
  font-style: italic;
  padding: 20px;
  text-align: center;
}

/* Scrollbar */
::-webkit-scrollbar { width: 6px; }
::-webkit-scrollbar-track { background: transparent; }
::-webkit-scrollbar-thumb { background: var(--border); border-radius: 3px; }
::-webkit-scrollbar-thumb:hover { background: var(--text-dim); }

/* Responsive */
@media (max-width: 1200px) {
  .grid {
    grid-template-columns: 1fr 1fr;
    grid-template-rows: auto auto auto;
  }
  .channels-panel { grid-column: 1 / 3; grid-row: 2; }
  .right-col { grid-column: 1 / 3; grid-row: 3; flex-direction: row; }
}
</style>
</head>
<body>

<div class="header">
  <div>
    <h1>youdown-brain</h1>
    <span style="color:var(--text-dim); font-size:12px;">Multi-Agent Pipeline Dashboard</span>
  </div>
  <div class="header-right">
    <span id="update-time">--</span>
    <span><span class="live-dot"></span> CANLI</span>
  </div>
</div>

<div class="grid">
  <!-- Pipeline Status -->
  <div class="panel pipeline-panel">
    <div class="panel-title">
      <span>Pipeline Durumu</span>
      <span id="phase-badge" class="phase-badge">--</span>
    </div>
    <div class="panel-body" id="pipeline-body">
      <div class="no-data">Pipeline baslatilmadi</div>
    </div>
  </div>

  <!-- Channels -->
  <div class="panel channels-panel">
    <div class="panel-title">
      <span>Kanal Mesajlari</span>
      <span id="msg-count" style="color:var(--text-dim)">0 mesaj</span>
    </div>
    <div class="panel-body" id="channels-body">
      <div class="no-data">Henuz mesaj yok</div>
    </div>
  </div>

  <!-- Right Column -->
  <div class="right-col">
    <!-- Agents -->
    <div class="panel agents-panel" style="flex: 0 0 auto;">
      <div class="panel-title">Ajanlar</div>
      <div class="panel-body" id="agents-body"></div>
    </div>

    <!-- Handoffs -->
    <div class="panel handoffs-panel" style="flex: 1;">
      <div class="panel-title">
        <span>Handoffs & QA</span>
        <span id="handoff-count" style="color:var(--text-dim)">0</span>
      </div>
      <div class="panel-body" id="handoffs-body">
        <div class="no-data">Henuz handoff yok</div>
      </div>
    </div>

    <!-- Logs -->
    <div class="panel logs-panel" style="flex: 1;">
      <div class="panel-title">
        <span>Son Loglar</span>
        <select id="log-select" style="background:var(--bg);color:var(--text);border:1px solid var(--border);border-radius:4px;padding:2px 6px;font-size:11px;">
          <option value="">-- sec --</option>
        </select>
      </div>
      <div class="panel-body" id="logs-body">
        <div class="no-data">Log secin</div>
      </div>
    </div>
  </div>

  <!-- QA Stats (bottom left) -->
  <div class="panel bottom-panel">
    <div class="panel-title">QA Istatistikleri</div>
    <div class="panel-body" id="qa-stats-body">
      <div class="no-data">Henuz QA verisi yok</div>
    </div>
  </div>
</div>

<script>
const AGENTS = [
  { id: 'ece', name: 'Ece', role: 'Architect' },
  { id: 'ceylin', name: 'Ceylin', role: 'Orchestrator' },
  { id: 'ismail', name: 'Ismail', role: 'Senior Dev' },
  { id: 'zeynep', name: 'Zeynep', role: 'UX Architect' },
  { id: 'hasan', name: 'Hasan', role: 'Backend' },
  { id: 'saki', name: 'Saki', role: 'Frontend' },
  { id: 'ahmet', name: 'Ahmet', role: 'QA' },
  { id: 'huseyin', name: 'Huseyin', role: 'DevOps' },
];

const STEP_ICONS = {
  pending: '\u23f3',
  in_progress: '\ud83d\udd04',
  done: '\u2705',
  failed: '\u274c',
  skipped: '\u23ed\ufe0f'
};

function formatTime(ts) {
  if (!ts) return '';
  const d = new Date(ts * 1000);
  return d.toLocaleTimeString('tr-TR', { hour: '2-digit', minute: '2-digit', second: '2-digit' });
}

function escapeHtml(str) {
  if (!str) return '';
  const d = document.createElement('div');
  d.textContent = str;
  return d.innerHTML;
}

function truncate(str, len) {
  if (!str) return '';
  return str.length > len ? str.substring(0, len) + '...' : str;
}

function renderPipeline(data) {
  const el = document.getElementById('pipeline-body');
  const badge = document.getElementById('phase-badge');
  if (!data) {
    el.innerHTML = '<div class="no-data">Pipeline baslatilmadi</div>';
    badge.textContent = '--';
    badge.className = 'phase-badge';
    return;
  }

  const phase = data.phase || 'unknown';
  badge.textContent = phase.toUpperCase();
  badge.className = `phase-badge phase-${phase}`;

  const total = data.steps_total || 0;
  const done = data.steps_done || 0;
  const pct = total > 0 ? Math.round(done / total * 100) : 0;
  const barClass = pct === 100 ? 'green' : pct > 50 ? 'orange' : 'orange';

  let html = `
    <div class="task-name">${escapeHtml(data.task || 'Gorev tanimlanmamis')}</div>
    <div style="font-size:12px;color:var(--text-dim);margin-bottom:4px;">
      Ilerleme: ${done}/${total} (%${pct})
    </div>
    <div class="progress-bar">
      <div class="progress-fill ${barClass}" style="width:${pct}%"></div>
    </div>
  `;

  if (data.steps && data.steps.length > 0) {
    html += '<ul class="step-list">';
    for (const s of data.steps) {
      const icon = STEP_ICONS[s.status] || '?';
      const retry = s.retry_count > 0 ? `<span class="step-retry">(retry:${s.retry_count})</span>` : '';
      const qa = s.qa_verdict ? `<span class="${s.qa_verdict === 'PASS' ? 'verdict-pass' : 'verdict-fail'}">[${s.qa_verdict}]</span>` : '';
      html += `
        <li class="step-item">
          <span class="step-icon">${icon}</span>
          <span class="step-id">#${s.id}</span>
          <span class="step-desc">${escapeHtml(truncate(s.desc, 40))}</span>
          <span class="step-assignee">${s.assignee || '?'}</span>
          ${retry}${qa}
        </li>`;
    }
    html += '</ul>';
  }

  if (data.blockers && data.blockers.length > 0) {
    html += `<div style="margin-top:8px;color:var(--orange);">Engeller: ${data.blockers.join(', ')}</div>`;
  }

  el.innerHTML = html;
}

function renderChannels(channels) {
  const el = document.getElementById('channels-body');
  const countEl = document.getElementById('msg-count');
  if (!channels || Object.keys(channels).length === 0) {
    el.innerHTML = '<div class="no-data">Henuz mesaj yok</div>';
    countEl.textContent = '0 mesaj';
    return;
  }

  let totalMsgs = 0;
  let html = '';
  const order = ['genel', 'tasarim', 'backend', 'qa', 'broadcast'];
  const sortedKeys = Object.keys(channels).sort((a, b) => {
    const ai = order.indexOf(a), bi = order.indexOf(b);
    return (ai === -1 ? 99 : ai) - (bi === -1 ? 99 : bi);
  });

  for (const ch of sortedKeys) {
    const msgs = channels[ch];
    if (msgs.length === 0) continue;
    totalMsgs += msgs.length;

    html += `<div class="channel-section ch-${ch}">`;
    html += `<div class="channel-header"><span>#${ch}</span><span>${msgs.length} mesaj</span></div>`;

    for (const m of msgs.slice(-10)) {
      const from = m.from || '?';
      const content = truncate(m.content || '', 200);
      const time = formatTime(m.timestamp);
      html += `
        <div class="msg">
          <span class="msg-from ${from}">${from}</span>
          <span class="msg-time">${time}</span>
          <div class="msg-content">${escapeHtml(content)}</div>
        </div>`;
    }
    html += '</div>';
  }

  el.innerHTML = html;
  countEl.textContent = `${totalMsgs} mesaj`;
}

function renderAgents(heartbeats) {
  const el = document.getElementById('agents-body');
  let html = '';
  for (const a of AGENTS) {
    const hb = heartbeats[a.id];
    let dotClass = 'unknown';
    let statusText = 'bekleniyor';
    if (hb) {
      dotClass = hb.alive ? 'alive' : 'dead';
      statusText = hb.alive ? `${hb.last_seen}s once` : `${hb.last_seen}s sessiz`;
    }
    html += `
      <div class="agent-row">
        <span class="agent-dot ${dotClass}"></span>
        <span class="agent-name">${a.name}</span>
        <span class="agent-status">${a.role} - ${statusText}</span>
      </div>`;
  }
  el.innerHTML = html;
}

function renderHandoffs(handoffs, qaVerdicts) {
  const el = document.getElementById('handoffs-body');
  const countEl = document.getElementById('handoff-count');
  const total = handoffs.length + qaVerdicts.length;
  countEl.textContent = total;

  if (total === 0) {
    el.innerHTML = '<div class="no-data">Henuz handoff yok</div>';
    return;
  }

  let html = '';

  for (const v of qaVerdicts.slice(-5)) {
    const icon = v.verdict === 'PASS' ? '\u2705' : '\u274c';
    const cls = v.verdict === 'PASS' ? 'verdict-pass' : 'verdict-fail';
    html += `<div class="handoff-item">${icon} QA #${v.task_id} <span class="${cls}">${v.verdict}</span> (deneme ${v.attempt})</div>`;
  }

  for (const h of handoffs.slice(-5)) {
    const icon = h.status === 'completed' ? '\u2705' : '\ud83d\udce9';
    html += `<div class="handoff-item">${icon} <strong>${h.from}</strong> <span class="handoff-arrow">\u2192</span> <strong>${h.to}</strong> <span style="color:var(--text-dim)">(${h.status})</span></div>`;
  }

  el.innerHTML = html;
}

function renderQAStats(pipeline) {
  const el = document.getElementById('qa-stats-body');
  if (!pipeline || !pipeline.qa_stats) {
    el.innerHTML = '<div class="no-data">Henuz QA verisi yok</div>';
    return;
  }
  const qa = pipeline.qa_stats;
  const steps = pipeline.steps || [];
  const passCount = steps.filter(s => s.qa_verdict === 'PASS').length;
  const failCount = steps.filter(s => s.qa_verdict === 'FAIL').length;
  const totalRetries = steps.reduce((sum, s) => sum + (s.retry_count || 0), 0);

  el.innerHTML = `
    <div style="display:grid;grid-template-columns:1fr 1fr;gap:8px;">
      <div style="padding:8px;background:var(--bg);border-radius:6px;text-align:center;">
        <div style="font-size:22px;font-weight:700;color:var(--green);">${passCount}</div>
        <div style="font-size:10px;color:var(--text-dim);">PASS</div>
      </div>
      <div style="padding:8px;background:var(--bg);border-radius:6px;text-align:center;">
        <div style="font-size:22px;font-weight:700;color:var(--red);">${failCount}</div>
        <div style="font-size:10px;color:var(--text-dim);">FAIL</div>
      </div>
      <div style="padding:8px;background:var(--bg);border-radius:6px;text-align:center;">
        <div style="font-size:22px;font-weight:700;color:var(--orange);">${totalRetries}</div>
        <div style="font-size:10px;color:var(--text-dim);">Toplam Retry</div>
      </div>
      <div style="padding:8px;background:var(--bg);border-radius:6px;text-align:center;">
        <div style="font-size:22px;font-weight:700;color:var(--purple);">${steps.length}</div>
        <div style="font-size:10px;color:var(--text-dim);">Toplam Adim</div>
      </div>
    </div>
  `;
}

function renderLogs(logs) {
  const select = document.getElementById('log-select');
  const currentVal = select.value;
  const existingOptions = new Set(Array.from(select.options).map(o => o.value));

  for (const name of Object.keys(logs)) {
    if (!existingOptions.has(name)) {
      const opt = document.createElement('option');
      opt.value = name;
      opt.textContent = name;
      select.appendChild(opt);
    }
  }

  if (currentVal && logs[currentVal]) {
    const el = document.getElementById('logs-body');
    el.innerHTML = logs[currentVal]
      .slice(-30)
      .map(line => `<div class="log-line">${escapeHtml(line)}</div>`)
      .join('');
    el.scrollTop = el.scrollHeight;
  }
}

async function fetchData() {
  try {
    const resp = await fetch('/api/status');
    const data = await resp.json();

    document.getElementById('update-time').textContent =
      new Date().toLocaleTimeString('tr-TR');

    renderPipeline(data.pipeline);
    renderChannels(data.channels);
    renderAgents(data.heartbeats);
    renderHandoffs(data.handoffs, data.qa_verdicts);
    renderQAStats(data.pipeline);
    renderLogs(data.logs);
  } catch (e) {
    console.error('Fetch error:', e);
  }
}

document.getElementById('log-select').addEventListener('change', fetchData);

fetchData();
setInterval(fetchData, 3000);
</script>
</body>
</html>"""


class DashboardHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/api/status":
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Cache-Control", "no-cache")
            self.end_headers()
            self.wfile.write(build_api_response().encode("utf-8"))
        elif self.path == "/" or self.path == "/index.html":
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            self.wfile.write(HTML_PAGE.encode("utf-8"))
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, format, *args):
        pass  # Sessiz calis


def main():
    server = http.server.HTTPServer(("0.0.0.0", PORT), DashboardHandler)
    print(f"""
╔══════════════════════════════════════════════╗
║      youdown-brain Web Dashboard             ║
╠══════════════════════════════════════════════╣
  URL  : http://localhost:{PORT}
  Dizin: {AGENTS_DIR}
  Dur  : Ctrl+C
╚══════════════════════════════════════════════╝
""")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nDashboard durduruldu.")
        server.server_close()


if __name__ == "__main__":
    main()
