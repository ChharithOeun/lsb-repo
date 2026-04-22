"""Tests for chharbot.tools - the dispatch/validation layer.

These run offline: we stub both bridges so no sockets or HTTP calls are made.
"""
from __future__ import annotations

import json
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional

import pytest

from chharbot.bridges import BridgeError
from chharbot.tools import build_tools, dispatch


class FakeAI:
    """Pretends to be an AIBridgeClient - records every call."""
    def __init__(self):
        self.calls: List[tuple] = []

    def get_state(self):               self.calls.append(("get_state",));            return {"name": "Chharbot", "hp": 100}
    def get_chat_tail(self, n=20):     self.calls.append(("get_chat_tail", n));      return [{"mode": 1, "text": "hi"}]
    def get_entities(self, radius=30): self.calls.append(("get_entities", radius));  return []
    def get_inventory(self, bag=None): self.calls.append(("get_inventory", bag));    return []
    def ping(self):                    self.calls.append(("ping",));                 return {"pong": True}
    def send_text(self, text):         self.calls.append(("send_text", text));       return {"ok": True}
    def target(self, entity_id):       self.calls.append(("target", entity_id));     return {"ok": True}


class FakeAdmin:
    def __init__(self, allow_writes=False):
        self.allow_writes = allow_writes
        self.calls: List[tuple] = []

    def health(self):          self.calls.append(("health",));       return {"ok": True}
    def server_stats(self):    self.calls.append(("server_stats",)); return {"chars": 2}
    def players(self):         self.calls.append(("players",));      return []
    def player(self, pid):     self.calls.append(("player", pid));   return {"id": pid}
    def zones(self):           self.calls.append(("zones",));        return []
    def event_tail(self, n=200): self.calls.append(("event_tail", n)); return {"lines": []}
    def version_sync_status(self): self.calls.append(("vsync_status",)); return {"in_sync": True}
    def announce(self, text):
        if not self.allow_writes: raise BridgeError("writes disabled")
        self.calls.append(("announce", text)); return {"ok": True}
    def tell(self, to, text):
        if not self.allow_writes: raise BridgeError("writes disabled")
        self.calls.append(("tell", to, text)); return {"ok": True}
    def version_sync_run(self, dry_run=True, force=False, override_dll=None, restart=True):
        if not self.allow_writes: raise BridgeError("writes disabled")
        self.calls.append(("vsync_run", dry_run, force, override_dll, restart))
        return {"ok": True}


# ---------- registry shape --------------------------------------------------

def test_read_only_has_no_write_tools():
    tools = build_tools(ai=FakeAI(), admin=FakeAdmin(), allow_writes=False)
    names = {t.name for t in tools}
    # No write verbs appear in read-only mode.
    assert "client_send_text" not in names
    assert "client_target"    not in names
    assert "server_announce"  not in names
    assert "server_tell"      not in names
    assert "version_sync_run" not in names
    # A core read surface is present.
    assert {"client_get_state", "server_stats", "server_list_players",
            "version_sync_status"} <= names


def test_writes_unlocked_by_flag():
    tools = build_tools(ai=FakeAI(), admin=FakeAdmin(allow_writes=True), allow_writes=True)
    names = {t.name for t in tools}
    assert {"client_send_text", "server_announce", "server_tell",
            "version_sync_run"} <= names
    for t in tools:
        if t.name.startswith(("client_send_text", "client_target",
                              "server_announce", "server_tell",
                              "version_sync_run")):
            assert t.read_only is False


def test_ai_absent_removes_client_tools():
    tools = build_tools(ai=None, admin=FakeAdmin(), allow_writes=False)
    names = {t.name for t in tools}
    assert not any(n.startswith("client_") for n in names)
    assert "server_stats" in names


# ---------- dispatch validation --------------------------------------------

def _tool(name, ai=None, admin=None, allow_writes=False):
    tools = build_tools(ai=ai or FakeAI(),
                        admin=admin or FakeAdmin(allow_writes=allow_writes),
                        allow_writes=allow_writes)
    for t in tools:
        if t.name == name:
            return t
    raise KeyError(name)


def test_dispatch_happy_path():
    tool = _tool("client_get_chat_tail")
    out = dispatch(tool, '{"n": 5}')
    assert "error" not in out
    assert out["result"] == [{"mode": 1, "text": "hi"}]


def test_dispatch_unknown_arg_rejected():
    tool = _tool("client_get_chat_tail")
    out = dispatch(tool, '{"n": 5, "rogue": true}')
    assert "error" in out
    assert "rogue" in out["error"]


def test_dispatch_non_json_returns_error_not_exception():
    tool = _tool("client_ping")
    out = dispatch(tool, "not json")
    assert "error" in out


def test_dispatch_bridge_error_is_captured():
    admin = FakeAdmin(allow_writes=False)
    tool = _tool("server_announce", admin=admin, allow_writes=True)
    # allow_writes=True on build but admin itself refuses -> BridgeError path.
    out = dispatch(tool, '{"text": "hi"}')
    assert "error" in out
    assert "writes disabled" in out["error"]


def test_dispatch_typeerror_on_missing_required_arg():
    tool = _tool("server_get_player")
    out = dispatch(tool, "{}")
    assert "error" in out
    assert "argument" in out["error"].lower()


def test_openai_shape_has_function_block():
    tool = _tool("server_stats")
    shape = tool.to_openai()
    assert shape["type"] == "function"
    assert shape["function"]["name"] == "server_stats"
    assert "parameters" in shape["function"]


def test_version_sync_run_dry_run_default():
    admin = FakeAdmin(allow_writes=True)
    tool = _tool("version_sync_run", admin=admin, allow_writes=True)
    out = dispatch(tool, "{}")
    assert "error" not in out
    # Default dry_run=True forwarded to the bridge.
    assert admin.calls[-1] == ("vsync_run", True, False, None, True)
