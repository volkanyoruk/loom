# Loom

```
 ╦   ╔═╗ ╔═╗ ╔╦╗
 ║   ║ ║ ║ ║ ║║║
 ╩═╝ ╚═╝ ╚═╝ ╩ ╩
 Multi-Agent AI Pipeline
```

[![Python 3.11+](https://img.shields.io/badge/python-3.11+-blue.svg)](https://www.python.org/downloads/)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![GitHub stars](https://img.shields.io/github/stars/volkanyoruk/loom?style=social)](https://github.com/volkanyoruk/loom)

**Multi-agent AI pipeline framework. Smart routing, parallel execution, dev-qa loops.**

---

## Why Loom?

| | Single Agent | Loom |
|---|---|---|
| Task analysis | You decide what to do | SmartRouter classifies and routes automatically |
| Execution | One agent, sequential | Up to 8 specialized agents in parallel |
| Quality | Hope for the best | Built-in dev-QA loop with retry |
| Complex tasks | One long, unfocused response | Decomposed, distributed, reviewed |
| Token usage | Wasteful on big tasks | Strategy-optimized (SINGLE to FULL) |

Loom does not replace your AI. It organizes it.

---

## Architecture

```
                         ┌─────────────┐
                         │    Task      │
                         └──────┬───────┘
                                │
                         ┌──────▼───────┐
                         │ SmartRouter   │
                         │ (heuristic +  │
                         │  AI classify) │
                         └──────┬───────┘
                                │
              ┌─────────────────┼─────────────────┐
              │                 │                  │
       ┌──────▼──────┐  ┌──────▼──────┐  ┌───────▼──────┐
       │   SINGLE    │  │    PAIR     │  │  TEAM / FULL │
       │  1 agent    │  │  dev + QA   │  │   parallel   │
       └──────┬──────┘  └──────┬──────┘  └───────┬──────┘
              │                │                  │
              │         ┌──────▼──────┐    ┌──────▼──────┐
              │         │  Dev-QA     │    │  Architect  │
              │         │  Loop       │    │  Director   │
              │         │  (retry)    │    │  Builder x  │
              │         └──────┬──────┘    │  Reviewer   │
              │                │           └──────┬──────┘
              └────────────────┼──────────────────┘
                               │
                        ┌──────▼───────┐
                        │   Result     │
                        └──────────────┘
```

---

## Quick Start

### Install

```bash
pip install loom-agents

# Or from source:
git clone https://github.com/volkanyoruk/loom.git
cd loom
pip install -e .
```

### Usage

```bash
# Simple task — SmartRouter picks the best strategy
loom "Add a login page" --project ~/myapp

# Ask a specific agent directly
loom "What is React?" --agent architect

# Force a strategy for complex work
loom "Big refactor" --strategy full

# Launch the web dashboard
loom --dashboard
```

The dashboard runs at `http://localhost:7777`.

---

## Agents

| Agent | Role | Description |
|-------|------|-------------|
| **Architect** | Chief Architect | Creates plans, defines system structure and technical decisions |
| **Director** | Orchestrator | Distributes tasks across agents, manages workflow |
| **Builder** | Senior Developer | Full-stack implementation, writes production code |
| **Designer** | UX Architect | Design systems, component patterns, user experience |
| **Backend** | Backend Engineer | API design, database modeling, server architecture |
| **Frontend** | Frontend Engineer | React/Vue components, UI implementation, styling |
| **Reviewer** | QA Engineer | Testing, code review, quality gate enforcement |
| **Deployer** | DevOps Engineer | CI/CD pipelines, infrastructure, deployment |

---

## Strategies

| Strategy | Agents | When | Est. Tokens |
|----------|--------|------|-------------|
| **SINGLE** | 1 | Simple questions, small fixes | ~2K |
| **PAIR** | 2 | Feature development (dev + QA loop) | ~8K |
| **TEAM** | 3-5 | Multi-file features, parallel execution | ~20K |
| **FULL** | 8 | Large refactors, new project scaffolding | ~50K |

SmartRouter selects the strategy automatically based on task complexity. You can override it with `--strategy`.

---

## Dashboard

Run `loom --dashboard` to launch the web UI at `localhost:7777`. The dashboard provides:

- Real-time agent activity and task progress
- Execution history and logs
- Strategy selection overview
- Token usage tracking

---

## Configuration

Loom works with your existing Claude CLI subscription. No API key required for CLI mode.

| Environment Variable | Description | Default |
|---------------------|-------------|---------|
| `CLAUDE_MODEL` | Model to use for agent tasks | `claude-sonnet-4-20250514` |
| `ANTHROPIC_API_KEY` | API key (optional, for direct API mode) | -- |

For API mode, install the optional dependency:

```bash
pip install loom-agents[api]
```

---

## Contributing

Contributions are welcome. Please open an issue first to discuss what you would like to change.

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/my-feature`)
3. Commit your changes
4. Push to the branch
5. Open a Pull Request

---

## License

[MIT](LICENSE) -- Volkan Yoruk
