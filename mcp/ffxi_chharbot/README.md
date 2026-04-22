# ffxi_chharbot MCP

Single-tool MCP wrapper around the `chharbot` local-model agent.

Where `ffxi_client` and `ffxi_admin` are one-MCP-tool-per-bridge-method
(the LLM drives the loop itself), this MCP exposes two tools:

| Tool | What it does |
|---|---|
| `chharbot_ask(prompt, allow_writes)` | Runs a full chharbot agent loop against a local LLM. Returns final answer + tool-call trace. |
| `chharbot_policy()` | Reports configured backend, model, bridge endpoints, whether writes are policy-allowed. |

## When to use which MCP

- **`ffxi_client` / `ffxi_admin`** — when you (Claude / whoever) want to
  plan the sequence of bridge calls yourself and keep each step in context.
- **`ffxi_chharbot`** — when you want to delegate a whole task ("figure
  out why X is failing and fix it if you can") to a local LLM that runs
  its own loop and returns the result. Saves round-trips and keeps the
  intermediate model chatter off the caller's context.

## Writes require two keys

`chharbot_ask(allow_writes=true)` on its own is not enough. The MCP
server must also be started with `CHHARBOT_ALLOW_WRITES=1`. Deliberate
redundancy so a caller can't unilaterally upgrade the agent's
permissions — the operator who configured `mcp.json` has final say.

## Install

```powershell
pip install fastmcp
pip install -e F:\ffxi\deploy\repo\chharbot
```

Then merge the `ffxi_chharbot` entry from `repo/mcp/mcp.example.json`
into your Claude config.
