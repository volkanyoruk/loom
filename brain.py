#!/usr/bin/env python3
"""
Loom — Multi-Agent Pipeline
Smart routing, parallel execution, dev-qa loops.

Usage:
    loom "Task description" --project /path/to/project
    loom "Simple question?"
    loom "Task" --agent builder           # Force specific agent
    loom "Task" --strategy full           # Force full pipeline
    loom --dashboard                      # Start web dashboard
    loom --dashboard --port 8080          # Custom port
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
║          Loom — Multi-Agent Pipeline         ║
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
  Strategy  : {c}{decision.strategy.value.upper()}\033[0m
  Agent     : {decision.agent}
  Reason    : {decision.reason}
  Est.      : ~{decision.estimated_tokens:,} tokens
""")


def print_usage(engine: AnthropicEngine):
    u = engine.usage_summary()
    print(f"""
\033[90m── Token Usage ──
  Input     : {u['input_tokens']:,}
  Output    : {u['output_tokens']:,}
  Cache hit : {u['cache_read_tokens']:,}
  Ratio     : {u['effective_cost_ratio']:.0%}\033[0m""")


async def run_task(args):
    """Main task execution."""
    print_header()

    # Init engine
    model = os.environ.get("CLAUDE_MODEL", "claude-sonnet-4-6")
    engine = AnthropicEngine(model=model)
    engine.load_agents(AGENTS_DEFS)

    # Project context
    project_root = Path(args.project).resolve() if args.project else Path.cwd()
    if project_root.exists():
        print(f"  Project   : {project_root}")
        engine.set_project_context(project_root)
    else:
        print(f"  \033[33mWarning: Project dir not found: {project_root}\033[0m")

    task = args.task

    # Event callback for live output
    async def on_event(event):
        etype = event.get("type", "")
        if etype == "status":
            phase = event.get("phase", "")
            print(f"\n\033[36m>>> Phase: {phase.upper()}\033[0m")
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
            print(f"    \033[32m[DEV]\033[0m Code written (attempt {attempt})")
        elif etype == "step_qa_done":
            verdict = event.get("verdict", "?")
            color = "\033[32m" if verdict == "PASS" else "\033[31m"
            print(f"    {color}[QA]\033[0m {verdict}")
        elif etype == "step_escalated":
            desc = event.get("desc", "?")
            print(f"    \033[31m[ESCALATED]\033[0m {desc}")
        elif etype == "level_start":
            level = event.get("level", "?")
            steps = event.get("steps", [])
            print(f"\n\033[35m>>> Level {level}: {len(steps)} tasks parallel\033[0m")
        elif etype == "error":
            msg = event.get("message", "?")
            print(f"\n  \033[31m[ERROR]\033[0m {msg}")
        elif etype == "agent_call":
            cache = event.get("cache_read", 0)
            if cache > 0:
                print(f"    \033[90m(cache hit: {cache} tokens)\033[0m")

    engine.event_callback = on_event
    pipeline = Pipeline(engine, project_root, event_callback=on_event)

    # Determine strategy
    if args.strategy:
        # Forced strategy
        strategy = Strategy(args.strategy)
        agent = args.agent or "builder"
        decision = RoutingDecision(
            strategy=strategy,
            agent=agent,
            team=None,
            reason="Manual selection",
            estimated_tokens=0,
        )
    elif args.agent:
        # Forced agent → SINGLE
        decision = RoutingDecision(
            strategy=Strategy.SINGLE,
            agent=args.agent,
            team=None,
            reason="Manual agent selection",
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
            result = await pipeline.run_team(decision.team or "design", task)
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
        description="Loom — Multi-Agent Pipeline",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  loom "Add login page" --project ~/myapp
  loom "Explain this function" --agent architect
  loom "Big refactor" --strategy full --project ~/myapp
  loom --dashboard
        """,
    )
    parser.add_argument("task", nargs="?", help="Task or question")
    parser.add_argument("--project", "-p", help="Project directory (default: cwd)")
    parser.add_argument("--agent", "-a", help="Use specific agent (e.g. builder, architect)")
    parser.add_argument("--strategy", "-s", choices=["single", "pair", "team", "full"],
                        help="Force strategy")
    parser.add_argument("--dashboard", "-d", action="store_true", help="Start web dashboard")
    parser.add_argument("--port", type=int, default=7777, help="Dashboard port (default: 7777)")
    parser.add_argument("--model", "-m", help="Claude model (default: claude-sonnet-4-6)")

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
