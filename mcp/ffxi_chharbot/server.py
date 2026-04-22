"""mcp_ffxi_chharbot - expose the chharbot *agent* (not just the bridges)
as a single MCP tool.

Where `ffxi_client` and `ffxi_admin` expose the raw bridge surface (one MCP
tool per bridge method, Claude drives the loop), `ffxi_chharbot` exposes
one high-level tool: `chharbot_ask(prompt, allow_writes)`. Each call runs
a complete chharbot agent loop against a local LLM and returns the final
answer. This keeps the cross-process hop count low when the work plan is
already a black box to the caller ("ask chharbot to figure out why
character X is stuck at the login gate and fix it").

Install deps:
    pip install fastmcp
    pip install -e <repo>/chharbot

Register in Claude's mcp.json:
    {
      "mcpServers": {
        "ffxi_chharbot": {
          "command": "python",
          "args": ["F:/ffxi/deploy/repo/mcp/ffxi_chharbot/server.py"],
          "env": {
            "CHHARBOT_BACKEND":  "ollama",
            "CHHARBOT_MODEL":    "llama3.1:8b-instruct-q4_K_M",
            "CHHARBOT_LLM_URL":  "http://127.0.0.1:11434",
            "LSB_ADMIN_TOKEN_FILE":  "F:/ffxi/deploy/.lsb_admin_token",
            "LSB_AIBRIDGE_TOKEN_FILE": "F:/ffxi/deploy/.aibridge_token"
          }
        }
      }
    }
"""
from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Any, Dict, Optional

try:
    from fastmcp import FastMCP
except ImportError as exc:  # pragma: no cover
    raise SystemExit("pip install fastmcp") from exc

try:
    from chharbot.agent import Agent, AgentConfig
    from chharbot.bridges import AdminAPIClient, AIBridgeClient, BridgeError
    from chharbot.llm import OllamaClient, OpenAICompatClient
except ImportError as exc:  # pragma: no cover
    raise SystemExit(
        "chharbot not importable. pip install -e <repo>/chharbot first."
    ) from exc


# ---------- configuration ----------------------------------------------------

BACKEND        = os.environ.get("CHHARBOT_BACKEND", "ollama").lower()
MODEL          = os.environ.get("CHHARBOT_MODEL",   "llama3.1:8b-instruct-q4_K_M")
LLM_URL        = os.environ.get("CHHARBOT_LLM_URL", "")
OPENAI_KEY     = os.environ.get("OPENAI_API_KEY",   "")

ADMIN_URL      = os.environ.get("LSB_ADMIN_URL",    "http://127.0.0.1:27116")
AI_HOST        = os.environ.get("AI_BRIDGE_HOST",   "127.0.0.1")
AI_PORT        = int(os.environ.get("AI_BRIDGE_PORT", "27115"))

ADMIN_TOK_FILE = os.environ.get("LSB_ADMIN_TOKEN_FILE",    r"F:\ffxi\deploy\.lsb_admin_token")
AI_TOK_FILE    = os.environ.get("LSB_AIBRIDGE_TOKEN_FILE", r"F:\ffxi\deploy\.aibridge_token")

# Default safety posture: do NOT let the MCP caller unlock writes unless
# they explicitly pass allow_writes=True AND the server was started with
# CHHARBOT_ALLOW_WRITES=1. Two keys, two turns.
ALLOW_WRITES_POLICY = os.environ.get("CHHARBOT_ALLOW_WRITES", "0") == "1"

MAX_STEPS  = int(os.environ.get("CHHARBOT_MAX_STEPS", "8"))
TEMPERATURE = float(os.environ.get("CHHARBOT_TEMPERATURE", "0.2"))


def _read_token(path: str) -> str:
    p = Path(path)
    if not p.exists():
        return ""
    return p.read_text(encoding="utf-8").strip()


def _make_llm():
    if BACKEND == "ollama":
        return OllamaClient(model=MODEL,
                            base_url=LLM_URL or "http://127.0.0.1:11434")
    return OpenAICompatClient(model=MODEL,
                               base_url=LLM_URL or "http://127.0.0.1:8080/v1",
                               api_key=OPENAI_KEY)


def _build_agent(allow_writes_request: bool) -> Agent:
    writes = bool(ALLOW_WRITES_POLICY and allow_writes_request)

    admin_tok = os.environ.get("LSB_ADMIN_TOKEN")    or _read_token(ADMIN_TOK_FILE)
    ai_tok    = os.environ.get("LSB_AIBRIDGE_TOKEN") or _read_token(AI_TOK_FILE)

    admin = AdminAPIClient(base_url=ADMIN_URL, token=admin_tok, allow_writes=writes)
    ai: Optional[AIBridgeClient] = None
    try:
        ai = AIBridgeClient(host=AI_HOST, port=AI_PORT, token=ai_tok)
        ai.connect()
        ai.ping()
    except BridgeError:
        # Fall back to server-only mode if the game client is offline.
        ai = None

    cfg = AgentConfig(llm=_make_llm(), ai=ai, admin=admin,
                      allow_writes=writes, max_steps=MAX_STEPS,
                      temperature=TEMPERATURE)
    return Agent(cfg)


# ---------- MCP server ------------------------------------------------------

mcp = FastMCP("ffxi_chharbot")


@mcp.tool
def chharbot_ask(prompt: str, allow_writes: bool = False) -> Dict[str, Any]:
    """Run a complete chharbot agent loop against a local LLM.

    The agent has access to:
      - read-only tools: player state, chat tail, entities, inventory,
        server stats, player list, zones, map_server log tail, version_sync
        status.
      - write tools (only when `allow_writes` is true AND the MCP server
        was started with CHHARBOT_ALLOW_WRITES=1): send_text, target,
        announce, tell, version_sync_run.

    Args:
        prompt:        plain-English instruction, e.g. "are we in sync
                       with retail? if not, do a dry-run and tell me what
                       would change."
        allow_writes:  true to let chharbot act on the world. Still gated
                       by the CHHARBOT_ALLOW_WRITES env var on the server.

    Returns:
        {
          "content":    final answer text from the local model,
          "steps":      number of LLM round-trips executed,
          "tool_calls": [ {name, arguments, result}, ... ] trace,
          "effective_writes": bool,  # whether writes were actually enabled
        }
    """
    agent = _build_agent(allow_writes_request=allow_writes)
    effective_writes = agent.cfg.allow_writes
    try:
        res = agent.run(prompt)
    except BridgeError as e:
        return {"content": f"(bridge error: {e})",
                "steps": 0, "tool_calls": [],
                "effective_writes": effective_writes}
    return {
        "content":          res.get("content") or "",
        "steps":            res.get("steps", 0),
        "tool_calls":       res.get("tool_calls", []),
        "effective_writes": effective_writes,
    }


@mcp.tool
def chharbot_policy() -> Dict[str, Any]:
    """Report the current chharbot MCP configuration (backend, model,
    bridge endpoints, whether writes are policy-allowed).

    Use this as a sanity check before chharbot_ask.
    """
    return {
        "backend":            BACKEND,
        "model":              MODEL,
        "llm_url":            LLM_URL or ("http://127.0.0.1:11434" if BACKEND == "ollama"
                                           else "http://127.0.0.1:8080/v1"),
        "admin_url":          ADMIN_URL,
        "ai_bridge":          f"{AI_HOST}:{AI_PORT}",
        "allow_writes_policy": ALLOW_WRITES_POLICY,
        "admin_token_present": bool(_read_token(ADMIN_TOK_FILE)),
        "ai_token_present":    bool(_read_token(AI_TOK_FILE)),
        "max_steps":          MAX_STEPS,
    }


if __name__ == "__main__":
    mcp.run()
