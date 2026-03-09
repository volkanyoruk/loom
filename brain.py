#!/usr/bin/env python3
"""
brain.py — youdown-brain v3
Smart multi-agent pipeline with prompt caching + parallel execution.

Usage:
    python3 brain.py "Gorev aciklamasi" --project /path/to/project
    python3 brain.py "Basit soru?"
    python3 brain.py "Gorev" --agent ismail           # Force specific agent
    python3 brain.py "Gorev" --strategy full           # Force full pipeline
    python3 brain.py --dashboard                       # Start web dashboard
    python3 brain.py --dashboard --port 8080           # Custom port
"""

import argparse
import asyncio
import json
import os
import sys
from pathlib import Path

# Add parent dir to path
sys.path.insert(0, str(Path(__file__).parent))

from engine import AnthropicEngine
from router import SmartRouter, Strategy, RoutingDecision
from pipeline import Pipeline


AGENTS_DIR = Path(__file__).parent
AGENTS_DEFS = AGENTS_DIR / "agents"
TEAMS_DIR = AGENTS_DIR / "teams"


def print_header():
    print("""
\033[36m╔══════════════════════════════════════════════╗
║     youdown-brain v3 — Smart Pipeline        ║
╚══════════════════════════════════════════════╝\033[0m""")


def print_routing(decision: RoutingDecision):
    colors = {
        Strategy.SINGLE: "\033[32m",       # green
        Strategy.PAIR: "\033[33m",          # yellow
        Strategy.TEAM: "\033[35m",          # magenta
        Strategy.FULL_PIPELINE: "\033[31m", # red
    }
    c = colors.get(decision.strategy, "")
    print(f"""
  Strateji  : {c}{decision.strategy.value.upper()}\033[0m
  Ajan      : {decision.agent}
  Sebep     : {decision.reason}
  Tahmini   : ~{decision.estimated_tokens:,} token
""")


def print_usage(engine: AnthropicEngine):
    u = engine.usage_summary()
    print(f"""
\033[90m── Token Kullanimi ──
  Input     : {u['input_tokens']:,}
  Output    : {u['output_tokens']:,}
  Cache hit : {u['cache_read_tokens']:,}
  Oran      : {u['effective_cost_ratio']:.0%}\033[0m""")


async def run_task(args):
    """Main task execution."""
    # Check API key
    if not os.environ.get("ANTHROPIC_API_KEY"):
        print("\033[31mHATA: ANTHROPIC_API_KEY ortam degiskeni gerekli.\033[0m")
        print("  export ANTHROPIC_API_KEY='sk-ant-...'")
        sys.exit(1)

    print_header()

    # Init engine
    model = os.environ.get("CLAUDE_MODEL", "claude-sonnet-4-6")
    engine = AnthropicEngine(model=model)
    engine.load_agents(AGENTS_DEFS)

    # Project context
    project_root = Path(args.project).resolve() if args.project else Path.cwd()
    if project_root.exists():
        print(f"  Proje    : {project_root}")
        engine.set_project_context(project_root)
    else:
        print(f"  \033[33mUyari: Proje dizini bulunamadi: {project_root}\033[0m")

    task = args.task

    # Event callback for live output
    async def on_event(event):
        etype = event.get("type", "")
        if etype == "status":
            phase = event.get("phase", "")
            print(f"\n\033[36m>>> Faz: {phase.upper()}\033[0m")
        elif etype == "agent_done":
            agent = event.get("agent", "?")
            action = event.get("action", "")
            print(f"  \033[32m[OK]\033[0m {agent} — {action}")
        elif etype == "step_start":
            sid = event.get("step_id", "?")
            desc = event.get("desc", "")
            assignee = event.get("assignee", "?")
            print(f"\n  \033[33m[#{sid}]\033[0m {desc} → {assignee}")
        elif etype == "step_worker_done":
            sid = event.get("step_id", "?")
            attempt = event.get("attempt", 1)
            print(f"    \033[32m[DEV]\033[0m Kod yazildi (deneme {attempt})")
        elif etype == "step_qa_done":
            verdict = event.get("verdict", "?")
            color = "\033[32m" if verdict == "PASS" else "\033[31m"
            print(f"    {color}[QA]\033[0m {verdict}")
        elif etype == "step_escalated":
            desc = event.get("desc", "?")
            print(f"    \033[31m[ESKALASYON]\033[0m {desc}")
        elif etype == "level_start":
            level = event.get("level", "?")
            steps = event.get("steps", [])
            print(f"\n\033[35m>>> Seviye {level}: {len(steps)} gorev paralel\033[0m")
        elif etype == "error":
            msg = event.get("message", "?")
            print(f"\n  \033[31m[HATA]\033[0m {msg}")
        elif etype == "agent_call":
            cache = event.get("cache_read", 0)
            if cache > 0:
                print(f"    \033[90m(cache hit: {cache} token)\033[0m")

    engine.event_callback = on_event
    pipeline = Pipeline(engine, project_root, event_callback=on_event)

    # Determine strategy
    if args.strategy:
        # Forced strategy
        strategy = Strategy(args.strategy)
        agent = args.agent or "ismail"
        decision = RoutingDecision(
            strategy=strategy,
            agent=agent,
            team=None,
            reason="Manuel secim",
            estimated_tokens=0,
        )
    elif args.agent:
        # Forced agent → SINGLE
        decision = RoutingDecision(
            strategy=Strategy.SINGLE,
            agent=args.agent,
            team=None,
            reason="Manuel ajan secimi",
            estimated_tokens=2000,
        )
    else:
        # Smart routing
        router = SmartRouter(engine)
        decision = await router.analyze(task, project_root)

    print_routing(decision)

    # Execute
    match decision.strategy:
        case Strategy.SINGLE:
            result = await pipeline.run_single(decision.agent, task)
            print(f"\n{'─' * 50}")
            print(result)

        case Strategy.PAIR:
            result = await pipeline.run_pair(decision.agent, task)
            print(f"\n{'─' * 50}")
            print(result)

        case Strategy.TEAM:
            result = await pipeline.run_team(decision.team or "tasarim", task)
            print(f"\n{'─' * 50}")
            print(result)

        case Strategy.FULL_PIPELINE:
            result = await pipeline.run_full(task)
            print(f"\n{'─' * 50}")
            print(result)

    print_usage(engine)


async def run_dashboard(port: int):
    """Start web dashboard."""
    # Import here to avoid circular
    from dashboard_v2 import start_dashboard
    await start_dashboard(port)


def main():
    parser = argparse.ArgumentParser(
        description="youdown-brain v3 — Smart Multi-Agent Pipeline",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Ornekler:
  python3 brain.py "Login sayfasi ekle" --project ~/myapp
  python3 brain.py "Bu fonksiyonu acikla" --agent ece
  python3 brain.py "Buyuk refactor" --strategy full --project ~/myapp
  python3 brain.py --dashboard
        """,
    )
    parser.add_argument("task", nargs="?", help="Gorev veya soru")
    parser.add_argument("--project", "-p", help="Proje dizini (varsayilan: mevcut dizin)")
    parser.add_argument("--agent", "-a", help="Belirli bir ajan kullan (orn: ismail, ece)")
    parser.add_argument("--strategy", "-s", choices=["single", "pair", "team", "full"],
                        help="Stratejiyi zorla")
    parser.add_argument("--dashboard", "-d", action="store_true", help="Web dashboard baslat")
    parser.add_argument("--port", type=int, default=7777, help="Dashboard portu (varsayilan: 7777)")
    parser.add_argument("--model", "-m", help="Claude model (varsayilan: claude-sonnet-4-6)")

    args = parser.parse_args()

    if args.model:
        os.environ["CLAUDE_MODEL"] = args.model

    if args.dashboard:
        print_header()
        print(f"  Dashboard : http://localhost:{args.port}")
        asyncio.run(run_dashboard(args.port))
    elif args.task:
        asyncio.run(run_task(args))
    else:
        parser.print_help()


if __name__ == "__main__":
    main()
