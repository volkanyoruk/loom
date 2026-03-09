"""
pipeline.py — Pipeline Engine
Async orchestration with parallel workers, dev-qa loop, SQLite state.
"""

import asyncio
import json
import os
import re
import subprocess
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from enum import Enum

import aiosqlite

from engine import AnthropicEngine
from router import Strategy, RoutingDecision


class StepStatus(str, Enum):
    PENDING = "pending"
    RUNNING = "in_progress"
    DONE = "done"
    FAILED = "failed"


@dataclass
class PipelineStep:
    id: int
    desc: str
    assignee: str
    team: str
    depends_on: list[int]
    acceptance_criteria: list[str]
    status: StepStatus = StepStatus.PENDING
    retry_count: int = 0
    qa_verdict: str | None = None
    error: str | None = None


@dataclass
class PipelineState:
    task: str
    phase: str = "planning"
    steps: list[PipelineStep] = field(default_factory=list)
    created_at: str = ""
    architecture: str = ""

    @property
    def steps_done(self) -> int:
        return sum(1 for s in self.steps if s.status == StepStatus.DONE)

    @property
    def steps_total(self) -> int:
        return len(self.steps)

    @property
    def progress_pct(self) -> int:
        return int(self.steps_done / self.steps_total * 100) if self.steps_total > 0 else 0

    def to_dict(self) -> dict:
        return {
            "task": self.task,
            "phase": self.phase,
            "steps_total": self.steps_total,
            "steps_done": self.steps_done,
            "created_at": self.created_at,
            "architecture": self.architecture,
            "steps": [
                {
                    "id": s.id, "desc": s.desc, "assignee": s.assignee,
                    "team": s.team, "status": s.status.value,
                    "retry_count": s.retry_count, "qa_verdict": s.qa_verdict,
                    "error_summary": s.error,
                }
                for s in self.steps
            ],
        }


class Pipeline:
    MAX_RETRIES = 3

    def __init__(self, engine: AnthropicEngine, project_root: Path,
                 db_path: Path | None = None, event_callback=None):
        self.engine = engine
        self.project_root = project_root
        self.db_path = db_path or (Path(__file__).parent / "data" / "sessions.db")
        self.state: PipelineState | None = None
        self.event_callback = event_callback
        self.messages: list[dict] = []  # in-memory message log

    async def emit(self, event: dict):
        """Emit event to dashboard/listeners."""
        event["timestamp"] = time.time()
        self.messages.append(event)
        if self.event_callback:
            await self.event_callback(event)

    # ═══════════════════════════════════════════
    #  STRATEGY EXECUTORS
    # ═══════════════════════════════════════════

    async def run_single(self, agent: str, task: str) -> str:
        """Single agent, direct answer."""
        await self.emit({"type": "status", "phase": "single", "agent": agent})
        result = await self.engine.call(agent, task)
        await self.emit({"type": "done", "agent": agent, "result_len": len(result)})
        return result

    async def run_pair(self, agent: str, task: str) -> str:
        """Developer + QA check."""
        await self.emit({"type": "status", "phase": "pair", "agent": agent})

        # Developer
        dev_prompt = f"""GOREV: {task}

PROJE DIZINI: {self.project_root}

Gorevi tamamla. Dosya degisikliklerini su formatta ver:

===FILE: dosya/yolu===
dosya icerigi
===END===

TAMAMLANDI bolumuyle ozetle."""

        dev_result = await self.engine.call(agent, dev_prompt)
        self._apply_code_changes(dev_result)
        await self.emit({"type": "agent_done", "agent": agent, "action": "implementation"})

        # QA
        qa_prompt = f"""GOREV: {task}

DEVELOPER ({agent}) CIKTISI:
{dev_result[:3000]}

Build calistir ve kontrol et. VERDICT: PASS veya FAIL"""

        qa_result = await self.engine.call("ahmet", qa_prompt)
        await self.emit({"type": "agent_done", "agent": "ahmet", "action": "qa"})

        verdict = "PASS" if re.search(r"(?i)VERDICT.*PASS", qa_result) else "FAIL"
        return f"Developer: {agent}\nQA: {verdict}\n\n{dev_result}"

    async def run_team(self, team: str, task: str) -> str:
        """Team execution — parallel agents from same team + QA."""
        teams_dir = Path(__file__).parent / "teams"
        team_file = teams_dir / f"{team}.json"

        members = ["ismail"]
        if team_file.exists():
            data = json.loads(team_file.read_text())
            members = data.get("members", ["ismail"])

        await self.emit({"type": "status", "phase": "team", "team": team, "members": members})

        # All team members work on the task in parallel
        results = await asyncio.gather(
            *[self.engine.call(m, f"GOREV: {task}\n\nSenin roldeki bakis acisiyla analiz et ve cozum uret.") for m in members]
        )

        combined = "\n---\n".join(f"**{m}:** {r[:2000]}" for m, r in zip(members, results))
        self._apply_code_changes(combined)

        # QA
        qa_result = await self.engine.call("ahmet", f"GOREV: {task}\n\nEKIP CIKTISI:\n{combined[:4000]}\n\nVERDICT: PASS veya FAIL")
        return combined

    async def run_full(self, task: str) -> str:
        """Full pipeline: Ece plans → parallel workers → QA loop."""
        self.state = PipelineState(
            task=task,
            created_at=datetime.now(timezone.utc).isoformat(),
        )

        # Phase 1: Planning (Ece)
        await self.emit({"type": "status", "phase": "planning"})
        plan = await self._plan(task)
        if not plan:
            return "Plan olusturulamadi."

        # Phase 2: Execution (parallel workers + QA)
        self.state.phase = "implementation"
        await self.emit({"type": "status", "phase": "implementation", "state": self.state.to_dict()})

        levels = self._topological_sort(self.state.steps)

        for level_idx, level in enumerate(levels):
            await self.emit({
                "type": "level_start",
                "level": level_idx + 1,
                "total_levels": len(levels),
                "steps": [s.id for s in level],
            })

            # Execute all steps in this level in parallel
            results = await asyncio.gather(
                *[self._execute_step(step) for step in level],
                return_exceptions=True,
            )

            # Check for failures
            for step, result in zip(level, results):
                if isinstance(result, Exception):
                    step.status = StepStatus.FAILED
                    step.error = str(result)

        # Phase 3: Done
        failed = [s for s in self.state.steps if s.status == StepStatus.FAILED]
        self.state.phase = "done" if not failed else "failed"
        await self.emit({"type": "status", "phase": self.state.phase, "state": self.state.to_dict()})

        return self._summary()

    # ═══════════════════════════════════════════
    #  PLANNING (Ece)
    # ═══════════════════════════════════════════

    async def _plan(self, task: str) -> dict | None:
        """Ece creates the execution plan."""
        plan_prompt = f"""GOREV: {task}

EKIPLER:
- Tasarim: ismail (Senior Dev) + zeynep (UX) — kanal: tasarim
- Backend: hasan (Backend) + saki (Frontend) — kanal: backend
- QA/DevOps: ahmet (QA) + huseyin (DevOps) — kanal: qa

ONEMLI:
- Paralel calisabilecek adimlari depends_on: [] ile isaretle
- Her adima net kabul kriterleri yaz
- Basit tut — gereksiz adim ekleme

SADECE JSON formatinda cevap ver:
{{
  "task": "gorev",
  "architecture": "teknik ozet",
  "steps": [
    {{
      "id": 1,
      "desc": "adim aciklamasi",
      "assignee": "ajan_adi",
      "team": "ekip",
      "depends_on": [],
      "acceptance_criteria": ["kriter"]
    }}
  ]
}}"""

        reply = await self.engine.call("ece", plan_prompt)
        await self.emit({"type": "agent_done", "agent": "ece", "action": "planning"})

        # Parse JSON from reply
        try:
            match = re.search(r'\{[\s\S]*\}', reply)
            if match:
                plan = json.loads(match.group())
                self.state.architecture = plan.get("architecture", "")
                for s in plan.get("steps", []):
                    self.state.steps.append(PipelineStep(
                        id=s["id"],
                        desc=s["desc"],
                        assignee=s.get("assignee", "ismail"),
                        team=s.get("team", "tasarim"),
                        depends_on=s.get("depends_on", []),
                        acceptance_criteria=s.get("acceptance_criteria", []),
                    ))
                return plan
        except (json.JSONDecodeError, KeyError) as e:
            await self.emit({"type": "error", "message": f"Plan parse hatasi: {e}"})
        return None

    # ═══════════════════════════════════════════
    #  STEP EXECUTION (Worker + QA Loop)
    # ═══════════════════════════════════════════

    async def _execute_step(self, step: PipelineStep):
        """Execute a single step: worker → QA → retry loop."""
        step.status = StepStatus.RUNNING
        await self.emit({
            "type": "step_start",
            "step_id": step.id,
            "desc": step.desc,
            "assignee": step.assignee,
        })

        for attempt in range(1, self.MAX_RETRIES + 1):
            step.retry_count = attempt - 1

            # Worker
            worker_prompt = self._build_worker_prompt(step, attempt)
            dev_result = await self.engine.call(step.assignee, worker_prompt)
            self._apply_code_changes(dev_result)

            await self.emit({
                "type": "step_worker_done",
                "step_id": step.id,
                "assignee": step.assignee,
                "attempt": attempt,
            })

            # QA
            qa_result = await self._qa_check(step, dev_result, attempt)
            verdict = "PASS" if re.search(r"(?i)VERDICT.*PASS", qa_result) else "FAIL"

            await self.emit({
                "type": "step_qa_done",
                "step_id": step.id,
                "verdict": verdict,
                "attempt": attempt,
            })

            if verdict == "PASS":
                step.status = StepStatus.DONE
                step.qa_verdict = "PASS"
                return

            # FAIL — feed QA feedback back to worker (multi-turn advantage!)
            step.qa_verdict = "FAIL"
            if attempt < self.MAX_RETRIES:
                # Worker already has context from multi-turn session
                fix_prompt = f"""QA BASARISIZ (deneme {attempt}/{self.MAX_RETRIES}).

QA GERI BILDIRIMI:
{qa_result[:2000]}

SADECE belirtilen sorunlari duzelt. Yeni ozellik ekleme.
Duzeltilmis dosyalari ===FILE: yol=== formatinda ver."""

                # This reuses the existing session — no need to resend full context!
                dev_result = await self.engine.call(step.assignee, fix_prompt)
                self._apply_code_changes(dev_result)

        # All retries exhausted
        step.status = StepStatus.FAILED
        step.error = f"QA {self.MAX_RETRIES} denemede gecemedi"
        await self.emit({
            "type": "step_escalated",
            "step_id": step.id,
            "desc": step.desc,
        })

    def _build_worker_prompt(self, step: PipelineStep, attempt: int) -> str:
        criteria_text = "\n".join(f"  - {c}" for c in step.acceptance_criteria)
        return f"""GOREV #{step.id}: {step.desc}

PROJE DIZINI: {self.project_root}
DENEME: {attempt}/{self.MAX_RETRIES}

KABUL KRITERLERI:
{criteria_text}

TALIMAT:
1. Gorevi tamamla
2. Dosya degisikliklerini su formatta ver:

===FILE: dosya/yolu===
tam dosya icerigi
===END===

3. Sonucu TAMAMLANDI bolumuyle ozetle"""

    async def _qa_check(self, step: PipelineStep, dev_output: str, attempt: int) -> str:
        criteria_text = "\n".join(f"  - {c}" for c in step.acceptance_criteria)

        # Build test
        build_result = self._run_build()

        qa_prompt = f"""GOREV #{step.id}: {step.desc}
DENEME: {attempt}/{self.MAX_RETRIES}

KABUL KRITERLERI:
{criteria_text}

DEVELOPER ({step.assignee}) CIKTISI:
{dev_output[:3000]}

BUILD SONUCU: {build_result}

Her kriteri tek tek kontrol et.
Ciktini su formatta ver:
VERDICT: PASS veya FAIL
ISSUES: (varsa)
FIX_INSTRUCTIONS: (FAIL ise)"""

        return await self.engine.call("ahmet", qa_prompt)

    # ═══════════════════════════════════════════
    #  UTILITIES
    # ═══════════════════════════════════════════

    def _topological_sort(self, steps: list[PipelineStep]) -> list[list[PipelineStep]]:
        """Group steps into parallelizable levels based on dependencies."""
        remaining = {s.id: s for s in steps}
        done_ids: set[int] = set()
        levels: list[list[PipelineStep]] = []

        while remaining:
            # Find steps whose dependencies are all done
            ready = [
                s for s in remaining.values()
                if all(d in done_ids for d in s.depends_on)
            ]
            if not ready:
                # Circular dependency or broken deps — just take remaining
                levels.append(list(remaining.values()))
                break

            levels.append(ready)
            for s in ready:
                done_ids.add(s.id)
                del remaining[s.id]

        return levels

    def _apply_code_changes(self, output: str):
        """Parse ===FILE: path===...===END=== blocks and write files."""
        pattern = r'===FILE:\s*(.+?)===\n(.*?)===END==='
        matches = re.findall(pattern, output, re.DOTALL)

        for filepath, content in matches:
            filepath = filepath.strip()
            # Security: path must stay within project root
            full_path = (self.project_root / filepath).resolve()
            if not str(full_path).startswith(str(self.project_root.resolve())):
                continue

            full_path.parent.mkdir(parents=True, exist_ok=True)
            full_path.write_text(content.strip() + "\n")

    def _run_build(self) -> str:
        """Run project build and return result."""
        if (self.project_root / "package.json").exists():
            cmd = "npm run build"
        elif (self.project_root / "Package.swift").exists():
            cmd = "swift build"
        else:
            return "skip (proje tipi tespit edilemedi)"

        try:
            result = subprocess.run(
                cmd, shell=True, cwd=self.project_root,
                capture_output=True, text=True, timeout=120,
            )
            if result.returncode == 0:
                return "success"
            return f"failed:\n{result.stderr[-500:]}"
        except subprocess.TimeoutExpired:
            return "timeout (120s)"
        except Exception as e:
            return f"error: {e}"

    def _summary(self) -> str:
        """Generate pipeline summary."""
        if not self.state:
            return "Pipeline baslatilmadi."

        s = self.state
        icons = {"done": "+", "failed": "X", "pending": ".", "in_progress": "~"}
        lines = [
            f"Pipeline: {s.phase.upper()}",
            f"Gorev: {s.task}",
            f"Ilerleme: {s.steps_done}/{s.steps_total} (%{s.progress_pct})",
            "",
        ]
        for step in s.steps:
            icon = icons.get(step.status.value, "?")
            retry = f" (retry:{step.retry_count})" if step.retry_count > 0 else ""
            qa = f" [QA:{step.qa_verdict}]" if step.qa_verdict else ""
            lines.append(f"  [{icon}] #{step.id} {step.desc} [{step.assignee}]{retry}{qa}")
            if step.error:
                lines.append(f"      ! {step.error}")

        # Token usage
        usage = self.engine.usage_summary()
        lines.extend([
            "",
            "Token Kullanimi:",
            f"  Input: {usage['input_tokens']:,} | Output: {usage['output_tokens']:,}",
            f"  Cache read: {usage['cache_read_tokens']:,} | Cache create: {usage['cache_creation_tokens']:,}",
            f"  Maliyet orani: {usage['effective_cost_ratio']:.0%} (dusuk = iyi)",
        ])

        return "\n".join(lines)

    def get_state_dict(self) -> dict:
        """Return current state for dashboard."""
        return {
            "pipeline": self.state.to_dict() if self.state else None,
            "messages": self.messages[-50:],
            "usage": self.engine.usage_summary(),
        }
