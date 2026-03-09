"""
engine.py — AnthropicEngine
Claude CLI (abonelik) veya Anthropic API (key) — ikisi de desteklenir.

Varsayilan: claude CLI kullanir, API key gerekmez.
API key varsa: dogrudan API + prompt caching (daha verimli).
"""

import os
import asyncio
import subprocess
import tempfile
from pathlib import Path
from dataclasses import dataclass, field


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
        if self.total_input == 0:
            return 1.0
        actual = self.input_tokens + self.cache_creation_tokens * 1.25 + self.cache_read_tokens * 0.1
        return actual / self.total_input


def _find_claude_bin() -> str:
    """claude binary'sini bul."""
    for path in [
        os.environ.get("CLAUDE_BIN", ""),
        "claude",
        os.path.expanduser("~/.local/bin/claude"),
        os.path.expanduser("~/.npm-global/bin/claude"),
        "/usr/local/bin/claude",
        "/opt/homebrew/bin/claude",
    ]:
        if path and os.path.isfile(path):
            return path
    return "claude"  # PATH'te olmali


class AnthropicEngine:
    """
    Ikili mod:
    - CLI modu  (varsayilan): claude CLI subprocess — API key gerekmez
    - API modu  (opsiyonel):  Anthropic SDK + prompt caching — ANTHROPIC_API_KEY gerekir
    """

    def __init__(self, model: str = "claude-sonnet-4-6", api_key: str | None = None):
        self.model = model
        self.agent_prompts: dict[str, str] = {}
        self.project_context: str = ""
        self.sessions: dict[str, list[dict]] = {}
        self.usage = TokenUsage()
        self.event_callback = None

        # Mod belirleme
        self.api_key = api_key or os.environ.get("ANTHROPIC_API_KEY", "")
        if self.api_key:
            try:
                import anthropic
                self._client = anthropic.AsyncAnthropic(api_key=self.api_key)
                self.mode = "api"
            except ImportError:
                self.mode = "cli"
                self._client = None
        else:
            self.mode = "cli"
            self._client = None

        self._claude_bin = _find_claude_bin()

    def load_agents(self, agents_dir: Path):
        """Ajan prompt dosyalarini yukle."""
        for f in agents_dir.glob("*.md"):
            self.agent_prompts[f.stem] = f.read_text()

    def set_project_context(self, project_root: Path, max_chars: int = 15000):
        """Proje dosyalarini oku. Her cagride tekrar gonderilmez (session memory)."""
        if not project_root.exists():
            self.project_context = ""
            return

        parts = []

        # Dosya agaci
        parts.append("## Proje Dosya Yapisi\n```")
        count = 0
        for p in sorted(project_root.rglob("*")):
            if count >= 50:
                break
            rel = p.relative_to(project_root)
            skip = any(s in str(rel) for s in [
                "node_modules", ".git", "__pycache__", ".DS_Store",
                "dist/", "build/", ".next/", "venv/", ".venv/", ".env"
            ])
            if skip or not p.is_file():
                continue
            parts.append(f"  {rel}")
            count += 1
        parts.append("```\n")

        # Dosya icerikleri
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
                "build/", ".next/", "venv/", ".venv/", "package-lock"
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

    def _build_full_prompt(self, agent_name: str, user_message: str) -> str:
        """CLI modu icin tam prompt olustur (sistem + context + gecmis + mesaj)."""
        parts = []

        # Ajan kisaligi
        agent_prompt = self.agent_prompts.get(agent_name, "")
        if agent_prompt:
            parts.append(agent_prompt)

        # Konusma gecmisi
        history = self.sessions.get(agent_name, [])

        # Proje context — gecmis yoksa (ilk cagri) ekle
        if self.project_context and not history:
            parts.append("\n---\n")
            parts.append(self.project_context)
        if history:
            parts.append("\n---\nOnceki konusma:\n")
            for msg in history[-6:]:  # Son 3 tur (6 mesaj)
                role_label = "Sen" if msg["role"] == "assistant" else "Kullanici"
                parts.append(f"{role_label}: {msg['content'][:1000]}")

        parts.append("\n---\n")
        parts.append(user_message)

        return "\n".join(parts)

    async def call(
        self,
        agent_name: str,
        user_message: str,
        include_project: bool = True,
        max_tokens: int = 8192,
        temperature: float = 0.3,
    ) -> str:
        """Bir ajani cagir. CLI veya API modunda otomatik calisir."""
        if self.mode == "api":
            return await self._call_api(agent_name, user_message, include_project, max_tokens, temperature)
        else:
            return await self._call_cli(agent_name, user_message)

    async def _call_cli(self, agent_name: str, user_message: str) -> str:
        """claude CLI ile cagri yap — API key gerekmez."""
        prompt = self._build_full_prompt(agent_name, user_message)

        # Gecici dosyaya yaz (uzun promptlar icin)
        with tempfile.NamedTemporaryFile(mode="w", suffix=".txt", delete=False, encoding="utf-8") as f:
            f.write(prompt)
            tmp_path = f.name

        MAX_RETRIES = 3
        BACKOFF = [5, 15, 30]
        reply = ""

        for attempt in range(MAX_RETRIES):
            try:
                env = {**os.environ}
                env.pop("CLAUDECODE", None)  # Claude Code modunu kapat

                result = await asyncio.get_event_loop().run_in_executor(
                    None,
                    lambda: subprocess.run(
                        [self._claude_bin, "--model", self.model, "-p", open(tmp_path).read()],
                        capture_output=True,
                        text=True,
                        env=env,
                        timeout=300,
                    )
                )

                if result.returncode == 0 and result.stdout and len(result.stdout.strip()) > 20:
                    reply = result.stdout.strip()
                    break

                if attempt < MAX_RETRIES - 1:
                    await asyncio.sleep(BACKOFF[attempt])

            except subprocess.TimeoutExpired:
                if attempt < MAX_RETRIES - 1:
                    await asyncio.sleep(BACKOFF[attempt])
            except Exception:
                if attempt < MAX_RETRIES - 1:
                    await asyncio.sleep(BACKOFF[attempt])

        try:
            os.unlink(tmp_path)
        except Exception:
            pass

        if not reply:
            return f"[{agent_name}]: Yanit alinamadi."

        # Session'a ekle
        history = self.sessions.get(agent_name, [])
        history.append({"role": "user", "content": user_message})
        history.append({"role": "assistant", "content": reply})
        self.sessions[agent_name] = history

        # Event
        if self.event_callback:
            await self.event_callback({
                "type": "agent_call",
                "agent": agent_name,
                "mode": "cli",
                "cache_read": 0,
            })

        return reply

    async def _call_api(
        self, agent_name: str, user_message: str,
        include_project: bool, max_tokens: int, temperature: float
    ) -> str:
        """Anthropic API ile cagri — prompt caching destekli."""
        blocks = []

        prompt = self.agent_prompts.get(agent_name, "")
        if prompt:
            block = {"type": "text", "text": prompt}
            if len(prompt) > 1000:
                block["cache_control"] = {"type": "ephemeral"}
            blocks.append(block)

        if include_project and self.project_context:
            blocks.append({
                "type": "text",
                "text": self.project_context,
                "cache_control": {"type": "ephemeral"}
            })

        history = self.sessions.get(agent_name, [])
        messages = history + [{"role": "user", "content": user_message}]

        response = await self._client.messages.create(
            model=self.model,
            max_tokens=max_tokens,
            system=blocks,
            messages=messages,
            temperature=temperature,
        )

        assistant_text = response.content[0].text
        messages.append({"role": "assistant", "content": assistant_text})
        self.sessions[agent_name] = messages

        u = response.usage
        self.usage.input_tokens += u.input_tokens
        self.usage.output_tokens += u.output_tokens
        if hasattr(u, "cache_read_input_tokens"):
            self.usage.cache_read_tokens += u.cache_read_input_tokens or 0
        if hasattr(u, "cache_creation_input_tokens"):
            self.usage.cache_creation_tokens += u.cache_creation_input_tokens or 0

        if self.event_callback:
            await self.event_callback({
                "type": "agent_call",
                "agent": agent_name,
                "mode": "api",
                "input_tokens": u.input_tokens,
                "output_tokens": u.output_tokens,
                "cache_read": getattr(u, "cache_read_input_tokens", 0) or 0,
            })

        return assistant_text

    async def call_cheap(self, prompt: str, max_tokens: int = 1024) -> str:
        """Hizli siniflandirma cagrisi (router icin). CLI'de normal model kullanir."""
        if self.mode == "api":
            response = await self._client.messages.create(
                model="claude-haiku-4-5-20251001",
                max_tokens=max_tokens,
                messages=[{"role": "user", "content": prompt}],
                temperature=0.0,
            )
            u = response.usage
            self.usage.input_tokens += u.input_tokens
            self.usage.output_tokens += u.output_tokens
            return response.content[0].text
        else:
            # CLI modunda ayni modeli kullan
            return await self._call_cli("_router", prompt)

    def reset_session(self, agent_name: str):
        self.sessions.pop(agent_name, None)

    def reset_all_sessions(self):
        self.sessions.clear()

    def usage_summary(self) -> dict:
        return {
            "mode": self.mode,
            "input_tokens": self.usage.input_tokens,
            "output_tokens": self.usage.output_tokens,
            "cache_read_tokens": self.usage.cache_read_tokens,
            "cache_creation_tokens": self.usage.cache_creation_tokens,
            "total_input": self.usage.total_input,
            "effective_cost_ratio": round(self.usage.effective_cost_ratio, 2),
        }
