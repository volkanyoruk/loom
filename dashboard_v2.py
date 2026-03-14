"""
dashboard_v2.py — Real-time Web Dashboard with WebSocket
Integrated with pipeline events. No polling — instant updates.
"""

import asyncio
import json
import os
import sys
import time
from pathlib import Path

from aiohttp import web

# Shared state
pipeline_ref = None
event_queue: asyncio.Queue = asyncio.Queue()
connected_ws: list[web.WebSocketResponse] = []
event_log: list[dict] = []


async def broadcast_event(event: dict):
    """Send event to all connected WebSocket clients."""
    event_log.append(event)
    if len(event_log) > 200:
        event_log.pop(0)
    data = json.dumps(event, ensure_ascii=False, default=str)
    dead = []
    for ws in connected_ws:
        try:
            await ws.send_str(data)
        except Exception:
            dead.append(ws)
    for ws in dead:
        connected_ws.remove(ws)


async def ws_handler(request):
    """WebSocket endpoint — real-time events."""
    ws = web.WebSocketResponse()
    await ws.prepare(request)
    connected_ws.append(ws)

    # Send history
    for event in event_log[-50:]:
        await ws.send_str(json.dumps(event, default=str))

    try:
        async for msg in ws:
            pass  # Client doesn't send, only receives
    finally:
        if ws in connected_ws:
            connected_ws.remove(ws)
    return ws


async def api_status(request):
    """REST fallback for dashboard data."""
    data = {
        "events": event_log[-50:],
        "timestamp": time.time(),
    }
    if pipeline_ref:
        data.update(pipeline_ref.get_state_dict())
    return web.json_response(data)


async def api_run(request):
    """Submit a task via API."""
    body = await request.json()
    task = body.get("task", "")
    project = body.get("project", "")
    strategy = body.get("strategy", "")

    if not task:
        return web.json_response({"error": "task gerekli"}, status=400)

    # Launch in background
    asyncio.create_task(_run_task_bg(task, project, strategy))
    return web.json_response({"status": "started", "task": task})


async def _run_task_bg(task: str, project: str, strategy: str):
    """Background task execution."""
    try:
        from engine import AnthropicEngine
        from router import SmartRouter, Strategy as S
        from pipeline import Pipeline

        engine = AnthropicEngine()
        engine.load_agents(Path(__file__).parent / "agents")
        engine.event_callback = broadcast_event

        project_root = Path(project) if project else Path.cwd()
        if project_root.exists():
            engine.set_project_context(project_root)

        global pipeline_ref
        pipeline = Pipeline(engine, project_root, event_callback=broadcast_event)
        pipeline_ref = pipeline

        router = SmartRouter(engine)

        if strategy:
            strat = S(strategy)
        else:
            decision = await router.analyze(task, project_root)
            strat = decision.strategy
            await broadcast_event({
                "type": "routing",
                "strategy": strat.value,
                "agent": decision.agent,
                "reason": decision.reason,
            })

        match strat:
            case S.SINGLE:
                result = await pipeline.run_single(decision.agent if not strategy else "builder", task)
            case S.PAIR:
                result = await pipeline.run_pair(decision.agent if not strategy else "builder", task)
            case S.TEAM:
                result = await pipeline.run_team(decision.team or "design", task)
            case S.FULL_PIPELINE:
                result = await pipeline.run_full(task)

        await broadcast_event({
            "type": "complete",
            "result_preview": result[:500] if result else "",
            "usage": engine.usage_summary(),
        })

    except Exception as e:
        await broadcast_event({"type": "error", "message": str(e)})


HTML = r"""<!DOCTYPE html>
<html lang="tr">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Loom</title>
<style>
:root {
  --bg: #0d1117; --surface: #161b22; --border: #30363d;
  --text: #e6edf3; --text-dim: #8b949e; --accent: #58a6ff;
  --green: #3fb950; --red: #f85149; --orange: #d29922;
  --purple: #bc8cff; --cyan: #39d2c0; --pink: #f778ba;
}
* { margin:0; padding:0; box-sizing:border-box; }
body {
  background: var(--bg); color: var(--text);
  font-family: 'SF Mono','Fira Code','JetBrains Mono', monospace;
  font-size: 13px; line-height: 1.5; padding: 16px;
}
h1 { font-size: 20px; font-weight: 700; color: var(--accent); }
.header {
  display: flex; justify-content: space-between; align-items: center;
  margin-bottom: 16px; padding-bottom: 12px; border-bottom: 1px solid var(--border);
}
.header-right { display: flex; align-items: center; gap: 16px; font-size: 12px; color: var(--text-dim); }
.live-dot {
  width: 8px; height: 8px; background: var(--green); border-radius: 50%;
  display: inline-block; animation: pulse 2s infinite;
}
@keyframes pulse { 0%,100%{opacity:1} 50%{opacity:0.3} }

.grid {
  display: grid;
  grid-template-columns: 1fr 360px;
  gap: 12px;
  height: calc(100vh - 80px);
}

/* Task Input */
.input-bar {
  grid-column: 1 / 3;
  display: flex; gap: 8px; align-items: center;
}
.input-bar input[type=text] {
  flex: 1; background: var(--surface); border: 1px solid var(--border);
  border-radius: 6px; padding: 10px 14px; color: var(--text);
  font-family: inherit; font-size: 13px; outline: none;
}
.input-bar input:focus { border-color: var(--accent); }
.input-bar button {
  background: var(--accent); color: #fff; border: none; border-radius: 6px;
  padding: 10px 20px; font-family: inherit; font-weight: 600; cursor: pointer;
  font-size: 13px;
}
.input-bar button:hover { opacity: 0.9; }
.input-bar select {
  background: var(--surface); color: var(--text); border: 1px solid var(--border);
  border-radius: 6px; padding: 10px; font-family: inherit; font-size: 12px;
}

/* Panels */
.panel {
  background: var(--surface); border: 1px solid var(--border);
  border-radius: 8px; overflow: hidden; display: flex; flex-direction: column;
}
.panel-title {
  padding: 10px 14px; font-size: 12px; font-weight: 600;
  text-transform: uppercase; letter-spacing: 0.5px;
  border-bottom: 1px solid var(--border); flex-shrink: 0;
  display: flex; justify-content: space-between; align-items: center;
}
.panel-body { padding: 10px 14px; overflow-y: auto; flex: 1; }

/* Event Feed */
.feed-panel { grid-column: 1; grid-row: 2; }
.feed-panel .panel-title { color: var(--cyan); border-bottom-color: var(--cyan); }

.event-item {
  padding: 6px 0; border-bottom: 1px solid var(--border);
  display: flex; gap: 8px; align-items: flex-start; font-size: 12px;
}
.event-item:last-child { border-bottom: none; }
.event-time { color: var(--text-dim); font-size: 10px; min-width: 60px; flex-shrink: 0; }
.event-icon { font-size: 14px; flex-shrink: 0; }
.event-text { flex: 1; word-break: break-word; }

/* Right sidebar */
.sidebar { grid-column: 2; grid-row: 2; display: flex; flex-direction: column; gap: 12px; }

.stats-panel .panel-title { color: var(--green); border-bottom-color: var(--green); }
.pipeline-panel .panel-title { color: var(--orange); border-bottom-color: var(--orange); }
.token-panel .panel-title { color: var(--purple); border-bottom-color: var(--purple); }

.stat-grid {
  display: grid; grid-template-columns: 1fr 1fr; gap: 8px;
}
.stat-box {
  padding: 10px; background: var(--bg); border-radius: 6px; text-align: center;
}
.stat-value { font-size: 22px; font-weight: 700; }
.stat-label { font-size: 10px; color: var(--text-dim); }

/* Pipeline steps */
.step-item {
  padding: 6px 0; border-bottom: 1px solid var(--border);
  display: flex; align-items: center; gap: 8px; font-size: 12px;
}
.step-item:last-child { border-bottom: none; }
.step-badge {
  font-size: 10px; padding: 1px 6px; border-radius: 4px;
  background: #1c2333; color: var(--purple);
}

/* Progress */
.progress-bar {
  width: 100%; height: 6px; background: var(--border);
  border-radius: 3px; margin: 8px 0; overflow: hidden;
}
.progress-fill {
  height: 100%; border-radius: 3px; background: var(--green);
  transition: width 0.5s ease;
}

.no-data { color: var(--text-dim); font-style: italic; padding: 20px; text-align: center; }

::-webkit-scrollbar { width: 6px; }
::-webkit-scrollbar-track { background: transparent; }
::-webkit-scrollbar-thumb { background: var(--border); border-radius: 3px; }
</style>
</head>
<body>

<div class="header">
  <div>
    <h1>Loom</h1>
    <span style="color:var(--text-dim);font-size:12px;">Smart Multi-Agent Pipeline</span>
  </div>
  <div class="header-right">
    <span id="status-text">Hazir</span>
    <span><span class="live-dot"></span> WS</span>
  </div>
</div>

<div class="grid">
  <!-- Task Input -->
  <div class="input-bar">
    <input type="text" id="task-input" placeholder="Gorev veya soru yaz..." />
    <input type="text" id="project-input" placeholder="Proje dizini (opsiyonel)" style="max-width:250px;" />
    <select id="strategy-select">
      <option value="">Otomatik</option>
      <option value="single">Tek Ajan</option>
      <option value="pair">Dev + QA</option>
      <option value="team">Ekip</option>
      <option value="full">Tam Pipeline</option>
    </select>
    <button onclick="submitTask()">Baslat</button>
  </div>

  <!-- Event Feed -->
  <div class="panel feed-panel">
    <div class="panel-title">
      <span>Canli Akis</span>
      <span id="event-count" style="color:var(--text-dim)">0 event</span>
    </div>
    <div class="panel-body" id="feed-body">
      <div class="no-data">Gorev baslatilmadi</div>
    </div>
  </div>

  <!-- Sidebar -->
  <div class="sidebar">
    <!-- Token Stats -->
    <div class="panel token-panel" style="flex: 0 0 auto;">
      <div class="panel-title">Token Kullanimi</div>
      <div class="panel-body">
        <div class="stat-grid" id="token-stats">
          <div class="stat-box">
            <div class="stat-value" style="color:var(--accent);" id="tok-input">0</div>
            <div class="stat-label">Input</div>
          </div>
          <div class="stat-box">
            <div class="stat-value" style="color:var(--green);" id="tok-cache">0</div>
            <div class="stat-label">Cache Hit</div>
          </div>
          <div class="stat-box">
            <div class="stat-value" style="color:var(--orange);" id="tok-output">0</div>
            <div class="stat-label">Output</div>
          </div>
          <div class="stat-box">
            <div class="stat-value" style="color:var(--purple);" id="tok-ratio">-</div>
            <div class="stat-label">Maliyet Orani</div>
          </div>
        </div>
      </div>
    </div>

    <!-- Pipeline Status -->
    <div class="panel pipeline-panel" style="flex: 1;">
      <div class="panel-title">
        <span>Pipeline</span>
        <span id="pipeline-phase" style="color:var(--text-dim)">--</span>
      </div>
      <div class="panel-body" id="pipeline-body">
        <div class="no-data">Henuz pipeline yok</div>
      </div>
    </div>

    <!-- Agent Activity -->
    <div class="panel stats-panel" style="flex: 0 0 auto;">
      <div class="panel-title">Ajan Aktivitesi</div>
      <div class="panel-body" id="agents-body">
        <div class="no-data">Bekleniyor</div>
      </div>
    </div>
  </div>
</div>

<script>
let ws;
let events = [];
let agentCalls = {};
let latestUsage = {};
let pipelineState = null;

const ICONS = {
  status: '\u{1f4e1}',
  routing: '\u{1f9ed}',
  agent_call: '\u26a1',
  agent_done: '\u2705',
  step_start: '\u{1f3af}',
  step_worker_done: '\u{1f4bb}',
  step_qa_done: '\u{1f50d}',
  step_escalated: '\u{1f6a8}',
  level_start: '\u{1f4ca}',
  complete: '\u{1f389}',
  error: '\u274c',
};

function formatTime(ts) {
  if (!ts) return '';
  return new Date(ts * 1000).toLocaleTimeString('tr-TR', {hour:'2-digit',minute:'2-digit',second:'2-digit'});
}

function escapeHtml(s) {
  const d = document.createElement('div'); d.textContent = s; return d.innerHTML;
}

function eventToText(e) {
  switch(e.type) {
    case 'status': return `Faz: <strong>${(e.phase||'').toUpperCase()}</strong>${e.agent ? ' ('+e.agent+')' : ''}`;
    case 'routing': return `Strateji: <strong style="color:var(--cyan)">${(e.strategy||'').toUpperCase()}</strong> [${e.agent}] — ${e.reason}`;
    case 'agent_call': return `<span style="color:var(--text-dim)">${e.agent} cagrisi (cache: ${(e.cache_read||0).toLocaleString()} tok)</span>`;
    case 'agent_done': return `<strong>${e.agent}</strong> tamamladi: ${e.action||''}`;
    case 'step_start': return `Gorev #${e.step_id}: ${escapeHtml(e.desc||'')} \u2192 <strong>${e.assignee}</strong>`;
    case 'step_worker_done': return `#${e.step_id} kod yazildi (deneme ${e.attempt||1})`;
    case 'step_qa_done': {
      const c = e.verdict==='PASS' ? 'var(--green)' : 'var(--red)';
      return `#${e.step_id} QA: <strong style="color:${c}">${e.verdict}</strong> (deneme ${e.attempt||1})`;
    }
    case 'step_escalated': return `<strong style="color:var(--red)">ESKALASYON</strong> #${e.step_id}: ${escapeHtml(e.desc||'')}`;
    case 'level_start': return `Seviye ${e.level}: ${(e.steps||[]).length} gorev paralel`;
    case 'complete': return `<strong style="color:var(--green)">TAMAMLANDI</strong>`;
    case 'error': return `<strong style="color:var(--red)">HATA:</strong> ${escapeHtml(e.message||'')}`;
    default: return JSON.stringify(e).substring(0, 150);
  }
}

function renderFeed() {
  const el = document.getElementById('feed-body');
  document.getElementById('event-count').textContent = events.length + ' event';
  if (events.length === 0) { el.innerHTML = '<div class="no-data">Gorev baslatilmadi</div>'; return; }

  el.innerHTML = events.slice(-100).map(e => `
    <div class="event-item">
      <span class="event-time">${formatTime(e.timestamp)}</span>
      <span class="event-icon">${ICONS[e.type]||'\u2022'}</span>
      <span class="event-text">${eventToText(e)}</span>
    </div>
  `).join('');
  el.scrollTop = el.scrollHeight;
}

function renderTokens(usage) {
  if (!usage) return;
  document.getElementById('tok-input').textContent = (usage.input_tokens||0).toLocaleString();
  document.getElementById('tok-cache').textContent = (usage.cache_read_tokens||0).toLocaleString();
  document.getElementById('tok-output').textContent = (usage.output_tokens||0).toLocaleString();
  const ratio = usage.effective_cost_ratio;
  document.getElementById('tok-ratio').textContent = ratio != null ? Math.round(ratio*100)+'%' : '-';
}

function renderPipeline(state) {
  const el = document.getElementById('pipeline-body');
  const phaseEl = document.getElementById('pipeline-phase');
  if (!state) { el.innerHTML = '<div class="no-data">Henuz pipeline yok</div>'; phaseEl.textContent='--'; return; }

  phaseEl.textContent = (state.phase||'').toUpperCase();
  const done = state.steps_done||0, total = state.steps_total||0;
  const pct = total > 0 ? Math.round(done/total*100) : 0;

  const STEP_ICONS = {pending:'\u23f3', in_progress:'\ud83d\udd04', done:'\u2705', failed:'\u274c'};

  let html = `
    <div style="font-size:14px;font-weight:600;margin-bottom:6px;">${escapeHtml(state.task||'')}</div>
    <div style="font-size:11px;color:var(--text-dim);">${done}/${total} (%${pct})</div>
    <div class="progress-bar"><div class="progress-fill" style="width:${pct}%"></div></div>
  `;

  if (state.steps) {
    for (const s of state.steps) {
      const icon = STEP_ICONS[s.status]||'?';
      const retry = s.retry_count > 0 ? `<span style="color:var(--orange);font-size:10px;"> retry:${s.retry_count}</span>` : '';
      const qa = s.qa_verdict ? `<span style="color:${s.qa_verdict==='PASS'?'var(--green)':'var(--red)'};font-size:10px;"> [${s.qa_verdict}]</span>` : '';
      html += `
        <div class="step-item">
          <span>${icon}</span>
          <span style="color:var(--text-dim);font-size:10px;min-width:24px;">#${s.id}</span>
          <span style="flex:1;">${escapeHtml((s.desc||'').substring(0,40))}</span>
          <span class="step-badge">${s.assignee||'?'}</span>
          ${retry}${qa}
        </div>`;
    }
  }
  el.innerHTML = html;
}

function renderAgents() {
  const el = document.getElementById('agents-body');
  const agents = Object.entries(agentCalls);
  if (agents.length === 0) { el.innerHTML = '<div class="no-data">Bekleniyor</div>'; return; }

  el.innerHTML = agents.map(([name, count]) => `
    <div style="display:flex;justify-content:space-between;padding:3px 0;border-bottom:1px solid var(--border);font-size:12px;">
      <span style="font-weight:600;">${name}</span>
      <span style="color:var(--text-dim);">${count} cagri</span>
    </div>
  `).join('');
}

function connectWS() {
  const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
  ws = new WebSocket(`${proto}//${location.host}/ws`);

  ws.onmessage = (msg) => {
    const e = JSON.parse(msg.data);
    events.push(e);

    // Track agent calls
    if (e.type === 'agent_call' && e.agent) {
      agentCalls[e.agent] = (agentCalls[e.agent]||0) + 1;
    }

    // Track pipeline state
    if (e.type === 'status' && e.state) pipelineState = e.state;
    if (e.type === 'complete' && e.usage) latestUsage = e.usage;

    renderFeed();
    renderAgents();
    if (pipelineState) renderPipeline(pipelineState);
    if (latestUsage) renderTokens(latestUsage);

    document.getElementById('status-text').textContent =
      e.type === 'complete' ? 'Tamamlandi' :
      e.type === 'error' ? 'Hata' : 'Calisiyor...';
  };

  ws.onclose = () => {
    document.getElementById('status-text').textContent = 'Baglanti kesildi';
    setTimeout(connectWS, 3000);
  };
}

async function submitTask() {
  const task = document.getElementById('task-input').value.trim();
  if (!task) return;

  const project = document.getElementById('project-input').value.trim();
  const strategy = document.getElementById('strategy-select').value;

  document.getElementById('status-text').textContent = 'Baslatiliyor...';
  events = [];
  agentCalls = {};
  pipelineState = null;
  renderFeed();

  await fetch('/api/run', {
    method: 'POST',
    headers: {'Content-Type': 'application/json'},
    body: JSON.stringify({ task, project, strategy }),
  });
}

document.getElementById('task-input').addEventListener('keydown', (e) => {
  if (e.key === 'Enter') submitTask();
});

connectWS();
</script>
</body>
</html>"""


async def start_dashboard(port: int = 7777):
    """Start the aiohttp web server with WebSocket support."""
    app = web.Application()
    app.router.add_get("/", lambda r: web.Response(text=HTML, content_type="text/html"))
    app.router.add_get("/ws", ws_handler)
    app.router.add_get("/api/status", api_status)
    app.router.add_post("/api/run", api_run)

    runner = web.AppRunner(app)
    await runner.setup()
    site = web.TCPSite(runner, "0.0.0.0", port)
    await site.start()

    print(f"""
\033[36m╔══════════════════════════════════════════════╗
║      Loom — Web Dashboard        ║
╠══════════════════════════════════════════════╣\033[0m
  URL  : http://localhost:{port}
  WS   : ws://localhost:{port}/ws
  API  : POST /api/run {{"task":"...", "project":"..."}}
\033[36m╚══════════════════════════════════════════════╝\033[0m
""")

    # Keep running
    try:
        while True:
            await asyncio.sleep(3600)
    except asyncio.CancelledError:
        pass
    finally:
        await runner.cleanup()


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 7777
    asyncio.run(start_dashboard(port))
