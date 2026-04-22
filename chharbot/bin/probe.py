"""probe.py - direct chharbot probe that prints full tracebacks.

Run this when smoke-test.ps1 complains and the PS wrapper is eating the
error. Writes a verbose trace to <repo>\\chharbot\\bin\\probe.log.

    python chharbot\\bin\\probe.py
"""
from __future__ import annotations

import json
import os
import sys
import traceback
from pathlib import Path


LOG = Path(__file__).with_name("probe.log")


def log(msg: str) -> None:
    print(msg)
    with LOG.open("a", encoding="utf-8") as f:
        f.write(msg + "\n")


def main() -> int:
    if LOG.exists():
        LOG.unlink()

    log(f"=== chharbot probe ===")
    log(f"python        : {sys.version}")
    log(f"executable    : {sys.executable}")
    log(f"cwd           : {os.getcwd()}")

    # 1. Import chharbot
    try:
        import chharbot  # noqa: F401
        log("import chharbot: OK")
    except Exception:
        log("import chharbot: FAIL")
        traceback.print_exc(file=sys.stdout)
        with LOG.open("a", encoding="utf-8") as f:
            traceback.print_exc(file=f)
        return 1

    # 2. Import submodules
    try:
        from chharbot.agent import Agent, AgentConfig
        from chharbot.bridges import AdminAPIClient, AIBridgeClient
        from chharbot.llm import OllamaClient, OpenAICompatClient
        log("import submodules: OK")
    except Exception:
        log("import submodules: FAIL")
        traceback.print_exc(file=sys.stdout)
        with LOG.open("a", encoding="utf-8") as f:
            traceback.print_exc(file=f)
        return 1

    # 3. Build a minimal config (no ai_bridge) and try a one-shot.
    try:
        llm = OllamaClient(model="llama3.1:8b-instruct-q4_K_M",
                           base_url="http://127.0.0.1:11434",
                           num_ctx=4096)
        # Read admin token the same way __main__.py does, so we can hit
        # authenticated endpoints like /version_sync/status.
        token_path = Path(r"F:\ffxi\deploy\.lsb_admin_token")
        admin_token = ""
        if token_path.exists():
            admin_token = token_path.read_text(encoding="utf-8").strip()
            log(f"admin token    : loaded ({len(admin_token)} chars) from {token_path}")
        else:
            log(f"admin token    : NOT FOUND at {token_path}")
        admin = AdminAPIClient(base_url="http://127.0.0.1:27116",
                               token=admin_token, allow_writes=False)
        cfg = AgentConfig(llm=llm, ai=None, admin=admin,
                          allow_writes=False, max_steps=4, temperature=0.2)
        log("build cfg      : OK")
    except Exception:
        log("build cfg      : FAIL")
        traceback.print_exc(file=sys.stdout)
        with LOG.open("a", encoding="utf-8") as f:
            traceback.print_exc(file=f)
        return 2

    # 4. Probe admin /health directly (doesn't touch the LLM at all).
    try:
        h = admin.health()
        log(f"admin.health   : {json.dumps(h)[:200]}")
    except Exception:
        log("admin.health   : FAIL")
        traceback.print_exc(file=sys.stdout)
        with LOG.open("a", encoding="utf-8") as f:
            traceback.print_exc(file=f)
        # don't bail - still try the LLM

    # 5. Probe Ollama tags (pure HTTP, no model work).
    try:
        import urllib.request
        with urllib.request.urlopen("http://127.0.0.1:11434/api/tags", timeout=5) as r:
            data = json.loads(r.read())
        names = [m.get("name") for m in (data.get("models") or [])]
        log(f"ollama tags    : {names}")
    except Exception:
        log("ollama tags    : FAIL")
        traceback.print_exc(file=sys.stdout)
        with LOG.open("a", encoding="utf-8") as f:
            traceback.print_exc(file=f)

    # 6. Sanity: raw LLM call with NO tools.
    try:
        raw = llm.chat([{"role": "user", "content": "Say 'ok' and nothing else."}],
                       tools=None, temperature=0.0)
        log(f"llm notools    : content={(raw.get('content') or '').strip()[:120]!r}")
    except Exception:
        log("llm notools    : FAIL")
        traceback.print_exc(file=sys.stdout)
        with LOG.open("a", encoding="utf-8") as f:
            traceback.print_exc(file=f)
        return 3

    # 7. Raw LLM call WITH tools (this is where 400s happen in agent.run).
    try:
        agent = Agent(cfg)
        tools_payload = agent._openai_tools()
        log(f"tools payload  : {len(tools_payload)} tool(s); first={json.dumps(tools_payload[0])[:200] if tools_payload else '-'}")
        raw = llm.chat([{"role": "user", "content": "List what tools you have."}],
                       tools=tools_payload, temperature=0.0)
        log(f"llm withtools  : content={(raw.get('content') or '').strip()[:120]!r}; "
            f"tool_calls={json.dumps(raw.get('tool_calls'))[:200]}")
    except Exception:
        log("llm withtools  : FAIL")
        traceback.print_exc(file=sys.stdout)
        with LOG.open("a", encoding="utf-8") as f:
            traceback.print_exc(file=f)
        # Continue — still try the full agent, but we know tools are broken.

    # 7b. Version-sync status (relevant to the FFXI-3331 fix).
    try:
        v = admin.version_sync_status()
        log(f"version_sync   : {json.dumps(v)[:600]}")
    except Exception:
        log("version_sync   : FAIL")
        traceback.print_exc(file=sys.stdout)
        with LOG.open("a", encoding="utf-8") as f:
            traceback.print_exc(file=f)

    # 8. Run the actual agent.
    try:
        agent = Agent(cfg)
        log(f"agent tools    : {[t.name for t in agent.tools]}")
        result = agent.run("How many zones have characters in them? Just the count.")
        log(f"steps          : {result.get('steps')}")
        log(f"tool_calls     : {json.dumps(result.get('tool_calls'))[:500]}")
        log(f"content        : {result.get('content')}")
        log("agent.run      : OK")
        return 0
    except Exception:
        log("agent.run      : FAIL")
        traceback.print_exc(file=sys.stdout)
        with LOG.open("a", encoding="utf-8") as f:
            traceback.print_exc(file=f)
        return 4


if __name__ == "__main__":
    sys.exit(main())
