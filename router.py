"""
router.py — Loom SmartRouter
Analyzes task complexity, routes to minimum agents needed.
Simple task = 1 call. Complex = full pipeline.
Saves 85-90% tokens on mixed workloads.
"""

import json
import re
from enum import Enum
from dataclasses import dataclass
from pathlib import Path

from engine import AnthropicEngine


class Strategy(Enum):
    SINGLE = "single"       # 1 agent, direct answer (~2K tokens)
    PAIR = "pair"           # dev + QA (~5K tokens)
    TEAM = "team"           # 2-3 agents parallel + QA (~12K tokens)
    FULL_PIPELINE = "full"  # All agents, full orchestration (~23K tokens)


@dataclass
class RoutingDecision:
    strategy: Strategy
    agent: str           # primary agent
    team: str | None     # team name if TEAM strategy
    reason: str
    estimated_tokens: int


# Agent expertise mapping
AGENT_SKILLS = {
    "architect": ["architecture", "planning", "design-review", "system-design"],
    "builder": ["fullstack", "react", "node", "swift", "python", "implementation"],
    "designer": ["ux", "ui", "design-system", "css", "accessibility", "figma"],
    "backend": ["backend", "api", "database", "sql", "redis", "microservices"],
    "frontend": ["frontend", "react", "css", "components", "responsive"],
    "reviewer": ["testing", "qa", "code-review", "security"],
    "deployer": ["devops", "deploy", "docker", "ci-cd", "monitoring"],
}

# Keyword → agent matching
KEYWORD_MAP = {
    "architect": r"(?i)(mimar|architect|plan|tasarla|strateji|analiz|design.?system)",
    "builder": r"(?i)(implement|yaz|kodla|full.?stack|swift|gelistir|ozellik|feature|bug.?fix|duzelt|build|write|code|develop)",
    "designer": r"(?i)(ui|ux|design|tasarim|renk|font|layout|responsive|erisile|figma|tema|theme|dark.?mode|color|style)",
    "backend": r"(?i)(api|endpoint|database|veritaban|sql|backend|sunucu|server|auth|redis|graphql|migration)",
    "frontend": r"(?i)(component|biles|frontend|react|css|stil|button|form|modal|sayfa|page|landing)",
    "reviewer": r"(?i)(test|qa|review|kontrol|incele|kalite|quality|guvenlik|security|bug|check)",
    "deployer": r"(?i)(deploy|docker|ci|cd|pipeline|nginx|ssl|monitoring|log|sunucu|server.?kur|infra)",
}

# Task complexity signals
SIMPLE_SIGNALS = [
    r"\?$",                          # Ends with question mark
    r"(?i)^(ne|nas[iı]l|neden|nere|ka[cç]|kim|what|how|why|where)",  # Question words
    r"(?i)(a[cç][ıi]kla|anlat|o(z|ö)etle|explain|describe|summarize)",  # Explain
    r"(?i)(kontrol et|review|incele|bak|check)",  # Review
]

COMPLEX_SIGNALS = [
    r"(?i)(uygulama|application|sistem|system)",
    r"(?i)(sayfa|page|ekran|screen).*ve.*",        # Multiple pages
    r"(?i)(entegr|integrat)",
    r"(?i)(migration|refactor)",
    r"(?i)\d+\s*(madde|adim|ozellik|item|step|feature)",   # Multiple items
]


class SmartRouter:

    def __init__(self, engine: AnthropicEngine):
        self.engine = engine

    async def analyze(self, task: str, project_root: Path | None = None) -> RoutingDecision:
        """Determine the optimal execution strategy for a task."""

        # Step 1: Fast heuristic check
        decision = self._heuristic_check(task)
        if decision:
            return decision

        # Step 2: Use AI for classification
        return await self._ai_classify(task, project_root)

    def _heuristic_check(self, task: str) -> RoutingDecision | None:
        """Fast pattern matching — no API call needed."""
        task_clean = task.strip()

        # Very short + question mark → SINGLE
        if len(task_clean) < 150 and any(re.search(p, task_clean) for p in SIMPLE_SIGNALS):
            agent = self._best_agent_for(task_clean)
            return RoutingDecision(
                strategy=Strategy.SINGLE,
                agent=agent,
                team=None,
                reason="Short question / explanation request",
                estimated_tokens=2000,
            )

        # Clearly complex → FULL_PIPELINE
        complex_count = sum(1 for p in COMPLEX_SIGNALS if re.search(p, task_clean))
        if complex_count >= 2 or len(task_clean) > 500:
            return RoutingDecision(
                strategy=Strategy.FULL_PIPELINE,
                agent="architect",
                team=None,
                reason=f"Complex task ({complex_count} signals)",
                estimated_tokens=23000,
            )

        # Single file/function mention → PAIR
        if re.search(r"(?i)(dosya|file|fonksiyon|function|metod|class|duzelt|fix|ekle|add|degistir|change)\b", task_clean) and len(task_clean) < 300:
            agent = self._best_agent_for(task_clean)
            return RoutingDecision(
                strategy=Strategy.PAIR,
                agent=agent,
                team=None,
                reason="Single file/function task",
                estimated_tokens=5000,
            )

        return None  # Not clear, use AI

    def _best_agent_for(self, task: str) -> str:
        """Match task keywords to best agent."""
        scores = {}
        for agent, pattern in KEYWORD_MAP.items():
            matches = len(re.findall(pattern, task))
            if matches > 0:
                scores[agent] = matches

        if scores:
            return max(scores, key=scores.get)
        return "builder"  # default: senior dev

    async def _ai_classify(self, task: str, project_root: Path | None = None) -> RoutingDecision:
        """Use AI to classify task complexity."""
        file_info = ""
        if project_root and project_root.exists():
            file_count = sum(1 for _ in project_root.rglob("*") if _.is_file() and ".git" not in str(_))
            file_info = f"\nPROJECT: {file_count} files"

        prompt = f"""Classify task complexity.

TASK: {task}{file_info}

AGENTS:
- architect: Architect (planning, analysis)
- builder: Senior Dev (fullstack, implementation)
- designer: UX (design, UI)
- backend: Backend (API, DB)
- frontend: Frontend (React, CSS)
- reviewer: QA (testing)
- deployer: DevOps (deploy)

CATEGORIES:
- SINGLE: Simple question, small fix, explanation. 1 agent enough.
- PAIR: Medium task, 1 developer + QA check needed.
- TEAM: Multiple skills from same area needed (e.g. UI design + frontend).
- FULL: Large feature, architectural change, multiple teams needed.

Reply ONLY in JSON:
{{"strategy": "SINGLE|PAIR|TEAM|FULL", "agent": "best_agent", "team": "team_name_or_null", "reason": "1 sentence"}}"""

        try:
            reply = await self.engine.call_cheap(prompt)
            # Extract JSON (markdown block or raw)
            match = re.search(r'```(?:json)?\s*(\{[^`]*?\})\s*```', reply)
            if match:
                data = json.loads(match.group(1))
            else:
                raw = re.search(r'\{[^}]+\}', reply)
                data = json.loads(raw.group()) if raw else None
            if data:
                strategy = Strategy(data.get("strategy", "pair").lower())
                tokens_map = {
                    Strategy.SINGLE: 2000,
                    Strategy.PAIR: 5000,
                    Strategy.TEAM: 12000,
                    Strategy.FULL_PIPELINE: 23000,
                }
                return RoutingDecision(
                    strategy=strategy,
                    agent=data.get("agent", "builder"),
                    team=data.get("team"),
                    reason=data.get("reason", "AI classification"),
                    estimated_tokens=tokens_map.get(strategy, 5000),
                )
        except Exception:
            pass

        # Fallback: PAIR with builder
        return RoutingDecision(
            strategy=Strategy.PAIR,
            agent=self._best_agent_for(task),
            team=None,
            reason="Default: developer + QA",
            estimated_tokens=5000,
        )
