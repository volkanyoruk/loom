"""
engine.py — AnthropicEngine
Direct Anthropic API with prompt caching + session memory.
Token savings: ~70% vs fresh prompts every call.
"""

import os
import asyncio
from pathlib import Path
from dataclasses import dataclass, field

import anthropic


@dataclass
class TokenUsage:
    input_tokens: int = 0
    output_tokens: int = 0
    cache_read_tokens: int = 0
    cache_creation_tokens: int = 0

    @property
    def total_input(self) -> int:
        return self.input_tokens + self.cache_read_tokens + self.cache_creation_tokens

    @property
    def effective_cost_ratio(self) -> float:
        """Cache read = 0.1x cost. Return effective ratio vs no-cache."""
        if self.total_input == 0:
            return 1.0
        full_cost = self.total_input  # without cache, all would be full price
        actual_cost = self.input_tokens + self.cache_creation_tokens * 1.25 + self.cache_read_tokens * 0.1
        return actual_cost / full_cost if full_cost > 0 else 1.0


class AnthropicEngine:
    """
    Anthropic API client with:
    - Prompt caching (cache_control) for agent prompts + project context
    - Multi-turn session memory per agent
    - Token usage tracking
    """

    def __init__(self, model: str = "claude-sonnet-4-6", api_key: str | None = None):
        self.model = model
        self.client = anthropic.AsyncAnthropic(
            api_key=api_key or os.environ.get("ANTHROPIC_API_KEY")
        )
        self.agent_prompts: dict[str, str] = {}
        self.project_context: str = ""
        self.sessions: dict[str, list[dict]] = {}
        self.usage = TokenUsage()
        self.event_callback = None  # pipeline/dashboard event hook

    def load_agents(self, agents_dir: Path):
        """Load agent personality prompts from markdown files."""
        for f in agents_dir.glob("*.md"):
            self.agent_prompts[f.stem] = f.read_text()

    def set_project_context(self, project_root: Path, max_chars: int = 15000):
        """Read project files once. Cached in all subsequent API calls."""
        if not project_root.exists():
            self.project_context = ""
            return

        parts = []

        # File tree
        parts.append("## Proje Dosya Yapisi\n```")
        count = 0
        for p in sorted(project_root.rglob("*")):
            if count >= 50:
                break
            rel = p.relative_to(project_root)
            # Skip noise
            skip = any(s in str(rel) for s in [
                "node_modules", ".git", "__pycache__", ".DS_Store",
                "dist/", "build/", ".next/", "venv/", ".env"
            ])
            if skip:
                continue
            if p.is_file():
                parts.append(f"  {rel}")
                count += 1
        parts.append("```\n")

        # Key files content
        parts.append("## Kod Icerigi\n")
        total = 0
        extensions = {".py", ".js", ".jsx", ".ts", ".tsx", ".swift", ".sh",
                      ".json", ".css", ".html", ".md", ".yaml", ".yml", ".toml"}
        for p in sorted(project_root.rglob("*")):
            if total >= max_chars:
                break
            if not p.is_file() or p.suffix not in extensions:
                continue
            rel = p.relative_to(project_root)
            skip = any(s in str(rel) for s in [
                "node_modules", ".git", "__pycache__", "dist/",
                "build/", ".next/", "venv/", "package-lock"
            ])
            if skip:
                continue
            try:
                content = p.read_text(errors="ignore")[:3000]
                parts.append(f"### {rel}\n```\n{content}\n```\n")
                total += len(content)
            except Exception:
                continue

        self.project_context = "\n".join(parts)

    def _build_system(self, agent_name: str, include_project: bool = True) -> list[dict]:
        """Build system message blocks with cache_control."""
        blocks = []

        # Agent personality — cached
        prompt = self.agent_prompts.get(agent_name, "")
        if prompt:
            block = {"type": "text", "text": prompt}
            # Mark for caching if big enough (>1024 tokens ~ 4000 chars)
            if len(prompt) > 1000:
                block["cache_control"] = {"type": "ephemeral"}
            blocks.append(block)

        # Project context — cached
        if include_project and self.project_context:
            blocks.append({
                "type": "text",
                "text": self.project_context,
                "cache_control": {"type": "ephemeral"}
            })

        return blocks

    async def call(
        self,
        agent_name: str,
        user_message: str,
        include_project: bool = True,
        max_tokens: int = 8192,
        temperature: float = 0.3,
    ) -> str:
        """
        Call an agent with prompt caching + session continuity.
        Multi-turn: previous messages kept for same agent.
        """
        system = self._build_system(agent_name, include_project)

        # Session history (multi-turn)
        history = self.sessions.get(agent_name, [])
        messages = history + [{"role": "user", "content": user_message}]

        response = await self.client.messages.create(
            model=self.model,
            max_tokens=max_tokens,
            system=system,
            messages=messages,
            temperature=temperature,
        )

        assistant_text = response.content[0].text

        # Update session
        messages.append({"role": "assistant", "content": assistant_text})
        self.sessions[agent_name] = messages

        # Track usage
        u = response.usage
        self.usage.input_tokens += u.input_tokens
        self.usage.output_tokens += u.output_tokens
        if hasattr(u, "cache_read_input_tokens"):
            self.usage.cache_read_tokens += u.cache_read_input_tokens or 0
        if hasattr(u, "cache_creation_input_tokens"):
            self.usage.cache_creation_tokens += u.cache_creation_input_tokens or 0

        # Emit event
        if self.event_callback:
            await self.event_callback({
                "type": "agent_call",
                "agent": agent_name,
                "input_tokens": u.input_tokens,
                "output_tokens": u.output_tokens,
                "cache_read": getattr(u, "cache_read_input_tokens", 0) or 0,
            })

        return assistant_text

    async def call_cheap(self, prompt: str, max_tokens: int = 1024) -> str:
        """Quick call with Haiku for routing/classification. No caching needed."""
        response = await self.client.messages.create(
            model="claude-haiku-4-5-20251001",
            max_tokens=max_tokens,
            messages=[{"role": "user", "content": prompt}],
            temperature=0.0,
        )
        # Track but separately
        u = response.usage
        self.usage.input_tokens += u.input_tokens
        self.usage.output_tokens += u.output_tokens
        return response.content[0].text

    def reset_session(self, agent_name: str):
        """Clear conversation history for an agent."""
        self.sessions.pop(agent_name, None)

    def reset_all_sessions(self):
        """Clear all agent sessions."""
        self.sessions.clear()

    def usage_summary(self) -> dict:
        """Token usage statistics."""
        return {
            "input_tokens": self.usage.input_tokens,
            "output_tokens": self.usage.output_tokens,
            "cache_read_tokens": self.usage.cache_read_tokens,
            "cache_creation_tokens": self.usage.cache_creation_tokens,
            "total_input": self.usage.total_input,
            "effective_cost_ratio": round(self.usage.effective_cost_ratio, 2),
        }
