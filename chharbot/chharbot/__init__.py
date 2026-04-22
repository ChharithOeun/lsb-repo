"""chharbot - local-model FFXI agent.

This is the "AI that plays the game" package. It drives the two v5 bridges
(ai_bridge on 127.0.0.1:27115 for client control, lsb_admin_api on
127.0.0.1:27116 for server ops) from a local LLM without requiring Claude in
the loop. It can talk to:

  - an Ollama daemon (default: http://127.0.0.1:11434)
  - any OpenAI-compatible chat-completions endpoint
  - an MCP server (by routing through mcp_ffxi_client / mcp_ffxi_admin)

Design principles:
  - No framework. The agent loop is ~200 lines; tools are plain functions.
  - Deterministic: every tool call is JSON-validated before dispatch, and
    every response shape is enforced. A malformed model reply produces a
    400-style error back to the model, not a crash.
  - Safe by default: the admin bridge is read-only unless `--allow-writes`
    is passed on the CLI.
"""
from .agent import Agent, AgentConfig, run_once
from .tools import TOOL_REGISTRY, Tool
from .llm import LLMClient, OllamaClient, OpenAICompatClient

__all__ = [
    "Agent", "AgentConfig", "run_once",
    "TOOL_REGISTRY", "Tool",
    "LLMClient", "OllamaClient", "OpenAICompatClient",
]

__version__ = "0.1.0"
