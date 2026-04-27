"""tools.py - the tool catalogue exposed to the local model.

Each tool is a `Tool` dataclass with a name, JSON-schema parameter definition,
and a plain-Python handler. The schema doubles as both the OpenAI-style
`tools=[...]` block sent to the model AND the validator that runs on every
call the model tries to make. A malformed call returns a structured
`{"error": ...}` to the model rather than raising.

Tools are grouped by bridge so the agent can filter by capability
(e.g. read-only mode exposes only `get_*` and `server_*`).
"""
from __future__ import annotations

import json
from dataclasses import dataclass, field
from typing import Any, Callable, Dict, List, Optional

from .bridges import AdminAPIClient, AIBridgeClient, BridgeError


@dataclass
class Tool:
    name: str
    description: str
    parameters: Dict[str, Any]      # JSON-schema
    handler: Callable[..., Any]     # keyword-arg callable
    read_only: bool = True

    def to_openai(self) -> Dict[str, Any]:
        return {
            "type": "function",
            "function": {
                "name": self.name,
                "description": self.description,
                "parameters": self.parameters,
            },
        }


def _obj(**props) -> Dict[str, Any]:
    return {"type": "object", "properties": props, "additionalProperties": False}


def build_tools(*, ai: Optional[AIBridgeClient], admin: AdminAPIClient,
                allow_writes: bool = False) -> List[Tool]:
    """Return the list of tools available given the connected bridges."""
    tools: List[Tool] = []

    # ---- read-only client tools (ai_bridge) --------------------------------
    if ai is not None:
        tools.extend([
            Tool(
                name="client_get_state",
                description="Snapshot of the player's current state: name, zone, HP/MP/TP, job levels, position, target id.",
                parameters=_obj(),
                handler=lambda: ai.get_state(),
            ),
            Tool(
                name="client_get_chat_tail",
                description="Return the last N chat lines the client has seen.",
                parameters=_obj(n={"type": "integer", "minimum": 1, "maximum": 200}),
                handler=lambda n=20: ai.get_chat_tail(n=n),
            ),
            Tool(
                name="client_get_entities",
                description="List entities within N yalms of the player.",
                parameters=_obj(radius={"type": "integer", "minimum": 1, "maximum": 50}),
                handler=lambda radius=30: ai.get_entities(radius=radius),
            ),
            Tool(
                name="client_get_inventory",
                description="Return inventory items. Omit 'bag' to read every bag the addon knows about.",
                parameters=_obj(bag={"type": "integer", "minimum": 0, "maximum": 16}),
                handler=lambda bag=None: ai.get_inventory(bag=bag),
            ),
            Tool(
                name="client_ping",
                description="Round-trip check on ai_bridge.",
                parameters=_obj(),
                handler=lambda: ai.ping(),
            ),
        ])
        if allow_writes:
            tools.extend([
                Tool(
                    name="client_send_text",
                    description="Type a line into the FFXI chat input. Max 400 characters; CR/LF stripped.",
                    parameters=_obj(text={"type": "string", "maxLength": 400}),
                    handler=lambda text: ai.send_text(text=text),
                    read_only=False,
                ),
                Tool(
                    name="client_target",
                    description="Target an entity by server id.",
                    parameters=_obj(entity_id={"type": "integer", "minimum": 1}),
                    handler=lambda entity_id: ai.target(entity_id=entity_id),
                    read_only=False,
                ),
            ])

    # ---- server read tools (lsb_admin_api) ---------------------------------
    tools.extend([
        Tool(
            name="server_health",
            description="Sidecar health probe (returns ts + token state).",
            parameters=_obj(),
            handler=lambda: admin.health(),
        ),
        Tool(
            name="server_stats",
            description="Totals of characters and accounts in the LSB database.",
            parameters=_obj(),
            handler=lambda: admin.server_stats(),
        ),
        Tool(
            name="server_list_players",
            description="Every character row (id, name, jobs, zone, account).",
            parameters=_obj(),
            handler=lambda: admin.players(),
        ),
        Tool(
            name="server_get_player",
            description="Single character by id.",
            parameters=_obj(pid={"type": "integer", "minimum": 1}),
            handler=lambda pid: admin.player(pid=pid),
        ),
        Tool(
            name="server_zones",
            description="Zones with current populations.",
            parameters=_obj(),
            handler=lambda: admin.zones(),
        ),
        Tool(
            name="server_event_tail",
            description="Last N lines of the map_server log.",
            parameters=_obj(n={"type": "integer", "minimum": 1, "maximum": 2000}),
            handler=lambda n=200: admin.event_tail(n=n),
        ),
        Tool(
            name="version_sync_status",
            description="Report on login.lua's CLIENT_VER vs the retail detection on this box.",
            parameters=_obj(),
            handler=lambda: admin.version_sync_status(),
        ),
    ])

    if allow_writes:
        tools.extend([
            Tool(
                name="server_announce",
                description="Broadcast a line to every connected player.",
                parameters=_obj(text={"type": "string", "maxLength": 400}),
                handler=lambda text: admin.announce(text=text),
                read_only=False,
            ),
            Tool(
                name="server_tell",
                description="Whisper a line to one player by name.",
                parameters=_obj(
                    to={"type": "string", "pattern": r"^[A-Za-z][A-Za-z0-9_.'\- ]{0,31}$"},
                    text={"type": "string", "maxLength": 400},
                ),
                handler=lambda to, text: admin.tell(to=to, text=text),
                read_only=False,
            ),
            Tool(
                name="version_sync_run",
                description="Run the retail->login.lua auto-match. Defaults to dry-run.",
                parameters=_obj(
                    dry_run={"type": "boolean"},
                    force={"type": "boolean"},
                    override_dll={"type": "string"},
                    restart={"type": "boolean"},
                ),
                handler=lambda dry_run=True, force=False, override_dll=None, restart=True:
                    admin.version_sync_run(dry_run=dry_run, force=force,
                                           override_dll=override_dll, restart=restart),
                read_only=False,
            ),
        ])

    return tools


TOOL_REGISTRY: Dict[str, Tool] = {}


def dispatch(tool: Tool, args_json: str) -> Dict[str, Any]:
    """Validate and run one tool call. Always returns a dict so the agent
    can feed the result back to the model as `role=tool` content.
    """
    try:
        args = json.loads(args_json) if args_json else {}
    except ValueError as e:
        return {"error": f"arguments not valid JSON: {e}"}
    if not isinstance(args, dict):
        return {"error": "arguments must be a JSON object"}
    # Reject unknown keys (additionalProperties=False).
    allowed = set(tool.parameters.get("properties", {}).keys())
    extra = set(args.keys()) - allowed
    if extra:
        return {"error": f"unknown argument(s): {sorted(extra)}"}
    try:
        result = tool.handler(**args)
    except TypeError as e:
        return {"error": f"argument mismatch: {e}"}
    except BridgeError as e:
        return {"error": f"bridge: {e}"}
    except Exception as e:  # pragma: no cover
        return {"error": f"{type(e).__name__}: {e}"}
    return {"result": result}
