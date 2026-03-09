"""
router.py — SmartRouter
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
    "ece": ["architecture", "planning", "design-review", "system-design"],
    "ismail": ["fullstack", "react", "node", "swift", "python", "implementation"],
    "zeynep": ["ux", "ui", "design-system", "css", "accessibility", "figma"],
    "hasan": ["backend", "api", "database", "sql", "redis", "microservices"],
    "saki": ["frontend", "react", "css", "components", "responsive"],
    "ahmet": ["testing", "qa", "code-review", "security"],
    "huseyin": ["devops", "deploy", "docker", "ci-cd", "monitoring"],
}

# Keyword → agent matching
KEYWORD_MAP = {
    "ece": r"(?i)(mimar|architect|plan|tasarla|strateji|analiz)",
    "ismail": r"(?i)(implement|yaz|kodla|full.?stack|swift|gelistir|ozellik|feature|bug.?fix|duzelt)",
    "zeynep": r"(?i)(ui|ux|design|tasarim|renk|font|layout|responsive|erisile|figma|tema|theme|dark.?mode)",
    "hasan": r"(?i)(api|endpoint|database|veritaban|sql|backend|sunucu|server|auth|redis|graphql)",
    "saki": r"(?i)(component|biles|frontend|react|css|stil|button|form|modal|sayfa|page)",
    "huseyin": r"(?i)(deploy|docker|ci|cd|pipeline|nginx|ssl|monitoring|log|sunucu|server.?kur)",
}

# Task complexity signals
SIMPLE_SIGNALS = [
    r"\?$",                          # Ends with question mark
    r"(?i)^(ne|nas[iı]l|neden|nere|ka[cç]|kim)",  # Question words
    r"(?i)(a[cç][ıi]kla|anlat|o(z|ö)etle)",        # Explain
    r"(?i)(kontrol et|review|incele|bak)",          # Review
]

COMPLEX_SIGNALS = [
    r"(?i)(uygulama|application|sistem|system)",
    r"(?i)(sayfa|page|ekran|screen).*ve.*",        # Multiple pages
    r"(?i)(entegr|integrat)",
    r"(?i)(migration|refactor)",
    r"(?i)\d+\s*(madde|adim|ozellik|item|step)",   # Multiple items
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

        # Step 2: Use Haiku for classification (costs ~$0.0002)
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
                reason="Kisa soru / aciklama talebi",
                estimated_tokens=2000,
            )

        # Clearly complex → FULL_PIPELINE
        complex_count = sum(1 for p in COMPLEX_SIGNALS if re.search(p, task_clean))
        if complex_count >= 2 or len(task_clean) > 500:
            return RoutingDecision(
                strategy=Strategy.FULL_PIPELINE,
                agent="ece",
                team=None,
                reason=f"Karmasik gorev ({complex_count} sinyal)",
                estimated_tokens=23000,
            )

        # Single file/function mention → PAIR
        if re.search(r"(?i)(dosya|file|fonksiyon|function|metod|class|duzelt|fix|ekle|add|degistir|change)\b", task_clean) and len(task_clean) < 300:
            agent = self._best_agent_for(task_clean)
            return RoutingDecision(
                strategy=Strategy.PAIR,
                agent=agent,
                team=None,
                reason="Tek dosya/fonksiyon gorevi",
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
        return "ismail"  # default: senior dev

    async def _ai_classify(self, task: str, project_root: Path | None = None) -> RoutingDecision:
        """Use Haiku to classify task complexity. Cost: ~$0.0002."""
        file_info = ""
        if project_root and project_root.exists():
            file_count = sum(1 for _ in project_root.rglob("*") if _.is_file() and ".git" not in str(_))
            file_info = f"\nPROJE: {file_count} dosya"

        prompt = f"""Gorev karmasikligini siniflandir.

GOREV: {task}{file_info}

AJANLAR:
- ece: Mimar (plan, analiz)
- ismail: Senior Dev (fullstack, implementasyon)
- zeynep: UX (tasarim, UI)
- hasan: Backend (API, DB)
- saki: Frontend (React, CSS)
- ahmet: QA (test)
- huseyin: DevOps (deploy)

KATEGORILER:
- SINGLE: Basit soru, kucuk duzeltme, aciklama. 1 ajan yeterli.
- PAIR: Orta gorev, 1 developer + QA kontrolu gerekli.
- TEAM: Ayni alandan birden fazla beceri gerekli (orn: UI tasarim + frontend).
- FULL: Buyuk ozellik, mimari degisiklik, birden fazla ekip gerekli.

SADECE JSON cevap ver:
{{"strategy": "SINGLE|PAIR|TEAM|FULL", "agent": "en_uygun_ajan", "team": "ekip_adi_veya_null", "reason": "1 cumle"}}"""

        try:
            reply = await self.engine.call_cheap(prompt)
            # Extract JSON
            match = re.search(r'\{[^}]+\}', reply)
            if match:
                data = json.loads(match.group())
                strategy = Strategy(data.get("strategy", "pair").lower())
                tokens_map = {
                    Strategy.SINGLE: 2000,
                    Strategy.PAIR: 5000,
                    Strategy.TEAM: 12000,
                    Strategy.FULL_PIPELINE: 23000,
                }
                return RoutingDecision(
                    strategy=strategy,
                    agent=data.get("agent", "ismail"),
                    team=data.get("team"),
                    reason=data.get("reason", "AI siniflandirma"),
                    estimated_tokens=tokens_map.get(strategy, 5000),
                )
        except Exception:
            pass

        # Fallback: PAIR with ismail
        return RoutingDecision(
            strategy=Strategy.PAIR,
            agent=self._best_agent_for(task),
            team=None,
            reason="Varsayilan: developer + QA",
            estimated_tokens=5000,
        )
