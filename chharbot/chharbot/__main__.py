"""CLI for chharbot.

Examples:

  # One-shot question against a running LSB + Ollama
  python -m chharbot "how many characters are in the database?"

  # Allow the agent to act (type chat, run version_sync, etc.)
  python -m chharbot --allow-writes "tell GUESTCL1 hello"

  # Point at a different local LLM (OpenAI-compatible)
  python -m chharbot --backend openai --model llama-3.1-8b-instruct \
      --llm-url http://127.0.0.1:8080/v1 "what's my HP?"

  # Interactive REPL
  python -m chharbot --repl
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path
from typing import Optional

from .agent import Agent, AgentConfig
from .bridges import AdminAPIClient, AIBridgeClient, BridgeError
from .llm import OllamaClient, OpenAICompatClient


def _read_token(path: str) -> str:
    p = Path(path)
    if not p.exists():
        return ""
    return p.read_text(encoding="utf-8").strip()


def _build_cfg(args: argparse.Namespace) -> AgentConfig:
    if args.backend == "ollama":
        llm = OllamaClient(model=args.model,
                           base_url=args.llm_url or "http://127.0.0.1:11434",
                           num_ctx=args.num_ctx)
    else:
        llm = OpenAICompatClient(
            model=args.model,
            base_url=args.llm_url or "http://127.0.0.1:8080/v1",
            api_key=os.environ.get("OPENAI_API_KEY", ""),
        )

    admin_token = os.environ.get("LSB_ADMIN_TOKEN") or _read_token(args.admin_token_file)
    ai_token    = os.environ.get("LSB_AIBRIDGE_TOKEN") or _read_token(args.aibridge_token_file)

    admin = AdminAPIClient(base_url=args.admin_url, token=admin_token,
                           allow_writes=args.allow_writes)
    ai: Optional[AIBridgeClient] = None
    if not args.no_ai_bridge:
        ai = AIBridgeClient(host=args.ai_host, port=args.ai_port, token=ai_token)
        if args.probe:
            try:
                ai.connect()
                ai.ping()
            except BridgeError as e:
                print(f"ai_bridge probe failed ({e}); continuing without client control",
                      file=sys.stderr)
                ai = None

    return AgentConfig(llm=llm, ai=ai, admin=admin,
                       allow_writes=args.allow_writes,
                       max_steps=args.max_steps,
                       temperature=args.temperature)


def _run_oneshot(prompt: str, cfg: AgentConfig, *, dump_trace: bool) -> int:
    agent = Agent(cfg)
    result = agent.run(prompt)
    if result.get("content"):
        print(result["content"])
    if dump_trace:
        print("---- tool trace ----", file=sys.stderr)
        print(json.dumps(result["tool_calls"], indent=2), file=sys.stderr)
    return 0


def _run_repl(cfg: AgentConfig, *, dump_trace: bool) -> int:
    agent = Agent(cfg)
    history: list = []
    print("chharbot REPL. Ctrl-D to exit.")
    while True:
        try:
            line = input(">>> ").strip()
        except (EOFError, KeyboardInterrupt):
            print()
            return 0
        if not line:
            continue
        if line in (".quit", ".exit"):
            return 0
        try:
            res = agent.run(line, history=history)
        except Exception as e:  # pragma: no cover
            print(f"(error) {type(e).__name__}: {e}", file=sys.stderr)
            continue
        history = res["messages"]
        if res.get("content"):
            print(res["content"])
        if dump_trace and res["tool_calls"]:
            print(json.dumps(res["tool_calls"], indent=2), file=sys.stderr)


def main(argv: Optional[list[str]] = None) -> int:
    ap = argparse.ArgumentParser(prog="chharbot", description=__doc__,
                                  formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("prompt", nargs="?", help="One-shot prompt (omit with --repl)")
    ap.add_argument("--repl", action="store_true", help="Interactive mode")
    ap.add_argument("--allow-writes", action="store_true",
                    help="Let the agent call server/client write tools")
    ap.add_argument("--trace", action="store_true",
                    help="Dump tool-call trace to stderr")
    ap.add_argument("--backend", choices=("ollama", "openai"), default="ollama")
    ap.add_argument("--model", default="llama3.1:8b-instruct-q4_K_M")
    ap.add_argument("--llm-url", default="")
    ap.add_argument("--admin-url", default="http://127.0.0.1:27116")
    ap.add_argument("--admin-token-file", default=r"F:\ffxi\deploy\.lsb_admin_token")
    ap.add_argument("--ai-host", default="127.0.0.1")
    ap.add_argument("--ai-port", type=int, default=27115)
    ap.add_argument("--aibridge-token-file", default=r"F:\ffxi\deploy\.aibridge_token")
    ap.add_argument("--no-ai-bridge", action="store_true",
                    help="Skip ai_bridge entirely (server-only agent)")
    ap.add_argument("--probe", action="store_true",
                    help="Ping ai_bridge at startup; drop it if unreachable")
    ap.add_argument("--max-steps", type=int, default=8)
    ap.add_argument("--temperature", type=float, default=0.2)
    ap.add_argument("--num-ctx", type=int, default=4096,
                    help="Ollama context window. Default 4096; raise if "
                         "responses are getting truncated and you have RAM.")
    args = ap.parse_args(argv)

    if not args.repl and not args.prompt:
        ap.error("either a prompt or --repl is required")

    cfg = _build_cfg(args)
    if args.repl:
        return _run_repl(cfg, dump_trace=args.trace)
    return _run_oneshot(args.prompt, cfg, dump_trace=args.trace)


if __name__ == "__main__":
    sys.exit(main())
