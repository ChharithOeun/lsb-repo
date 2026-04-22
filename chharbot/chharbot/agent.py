"""agent.py - the ReAct-style loop that turns a local LLM into a chharbot.

Flow per turn:
  1. Send messages + tool catalogue to the LLM.
  2. If the reply contains tool_calls, dispatch each one, append the results
     as role=tool messages, and continue.
  3. If the reply is content-only, that's the final answer; return it.
  4. Bail at max_steps so a runaway tool-call loop can't spin forever.

No external agent framework - the whole state machine is ~80 lines. This is
deliberate: the FFXI loop has to be debuggable by reading one file.
"""
from __future__ import annotations

import json
import logging
import time
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional

from .bridges import AdminAPIClient, AIBridgeClient
from .llm import LLMClient
from .tools import Tool, build_tools, dispatch


_log = logging.getLogger("chharbot")


DEFAULT_SYSTEM = """You are Chharbot, an assistant embedded in a LandSandBoat
(FFXI private server) deployment. You have two ways to act:

  - client_*     — drive the FFXI game client (read state, optionally type chat / target)
  - server_*     — query the LSB server's database and map_server log
  - version_sync_* — inspect or re-sync the login.lua <-> retail version

Rules of thumb:
  - Read before you act. When the user asks what's going on, call the
    relevant get_* / list_* / status tool first.
  - Prefer dry-runs when a tool supports them.
  - Be concise. Once you have enough data to answer, stop calling tools
    and return the answer in plain text.
  - If a tool returns {"error": ...}, do NOT retry with the same arguments
    blindly. Either fix the arguments or report the problem to the user.
"""


@dataclass
class AgentConfig:
    llm: LLMClient
    ai: Optional[AIBridgeClient]
    admin: AdminAPIClient
    allow_writes: bool = False
    system: str = DEFAULT_SYSTEM
    max_steps: int = 8
    temperature: float = 0.2


@dataclass
class Agent:
    cfg: AgentConfig
    _tools: List[Tool] = field(default_factory=list)
    _tool_by_name: Dict[str, Tool] = field(default_factory=dict)

    def __post_init__(self) -> None:
        self._tools = build_tools(ai=self.cfg.ai, admin=self.cfg.admin,
                                  allow_writes=self.cfg.allow_writes)
        self._tool_by_name = {t.name: t for t in self._tools}

    @property
    def tools(self) -> List[Tool]:
        return list(self._tools)

    def _openai_tools(self) -> List[Dict[str, Any]]:
        return [t.to_openai() for t in self._tools]

    def run(self, user: str, *, history: Optional[List[Dict[str, Any]]] = None) -> Dict[str, Any]:
        """Run one user request to completion. Returns
        {content, messages, steps, tool_calls}."""
        messages: List[Dict[str, Any]] = list(history or [])
        if not any(m.get("role") == "system" for m in messages):
            messages.insert(0, {"role": "system", "content": self.cfg.system})
        messages.append({"role": "user", "content": user})

        tool_trace: List[Dict[str, Any]] = []
        steps = 0
        final_content: Optional[str] = None

        while steps < self.cfg.max_steps:
            steps += 1
            resp = self.cfg.llm.chat(messages, tools=self._openai_tools(),
                                     temperature=self.cfg.temperature)
            content = resp.get("content")
            calls = resp.get("tool_calls") or []

            # Capture assistant turn (with or without tool_calls).
            assistant_msg: Dict[str, Any] = {"role": "assistant", "content": content or ""}
            if calls:
                assistant_msg["tool_calls"] = [
                    {"id": c["id"], "type": "function",
                     "function": {"name": c["name"], "arguments": c["arguments"]}}
                    for c in calls
                ]
            messages.append(assistant_msg)

            if not calls:
                final_content = content or ""
                break

            # Dispatch every call the model asked for.
            for c in calls:
                name = c.get("name") or ""
                args_json = c.get("arguments") or "{}"
                tool = self._tool_by_name.get(name)
                if tool is None:
                    out: Dict[str, Any] = {"error": f"unknown tool: {name!r}"}
                else:
                    out = dispatch(tool, args_json)
                tool_trace.append({"name": name, "arguments": args_json, "result": out})
                messages.append({
                    "role": "tool",
                    "tool_call_id": c["id"],
                    "name": name,
                    "content": json.dumps(out),
                })
        else:
            final_content = (
                f"(agent: stopped at max_steps={self.cfg.max_steps}; last tool: "
                f"{tool_trace[-1]['name'] if tool_trace else 'none'})"
            )

        return {
            "content":    final_content,
            "messages":   messages,
            "steps":      steps,
            "tool_calls": tool_trace,
        }


def run_once(prompt: str, cfg: AgentConfig) -> Dict[str, Any]:
    """One-shot helper, equivalent to `Agent(cfg).run(prompt)`."""
    return Agent(cfg).run(prompt)
