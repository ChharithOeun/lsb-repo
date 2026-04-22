"""End-to-end agent loop tests using a scripted fake LLM.

We wire a canned list of LLM responses into OllamaClient's stand-in and
assert the agent loop dispatches tools in order, feeds results back, and
terminates on the first content-only reply.
"""
from __future__ import annotations

import json
from typing import Any, Dict, List, Optional

import pytest

from chharbot.agent import Agent, AgentConfig
from chharbot.bridges import AdminAPIClient, AIBridgeClient
from chharbot.llm import LLMClient

from tests.test_tools import FakeAI, FakeAdmin


class ScriptedLLM(LLMClient):
    """Replays a pre-baked list of responses. Each call pops the head of
    `self.script` and returns it."""

    def __init__(self, script: List[Dict[str, Any]]):
        super().__init__(base_url="http://fake", model="scripted")
        self.script = list(script)
        self.received: List[List[Dict[str, Any]]] = []

    def chat(self, messages, tools=None, temperature=0.2):
        # Shallow-copy so tests can assert on the sequence.
        self.received.append([dict(m) for m in messages])
        if not self.script:
            raise AssertionError("ScriptedLLM: ran out of canned responses")
        return self.script.pop(0)


def _cfg(script, *, allow_writes=False, max_steps=6):
    ai = FakeAI()
    admin = FakeAdmin(allow_writes=True) if allow_writes else FakeAdmin()
    llm = ScriptedLLM(script)
    return AgentConfig(llm=llm, ai=ai, admin=admin,
                       allow_writes=allow_writes, max_steps=max_steps)


def _call(id_: str, name: str, args: Dict[str, Any]) -> Dict[str, Any]:
    return {"id": id_, "name": name, "arguments": json.dumps(args)}


def test_single_tool_then_final_answer():
    cfg = _cfg([
        {"content": None, "tool_calls": [_call("c1", "server_stats", {})], "raw": {}},
        {"content": "2 characters.", "tool_calls": [], "raw": {}},
    ])
    res = Agent(cfg).run("how many chars?")
    assert res["content"] == "2 characters."
    assert res["steps"] == 2
    assert [c["name"] for c in res["tool_calls"]] == ["server_stats"]
    assert res["tool_calls"][0]["result"] == {"result": {"chars": 2}}


def test_multi_tool_chain():
    cfg = _cfg([
        {"content": None, "tool_calls": [_call("c1", "client_get_state", {})], "raw": {}},
        {"content": None, "tool_calls": [_call("c2", "client_get_chat_tail", {"n": 5})], "raw": {}},
        {"content": "HP 100, last chat recorded.", "tool_calls": [], "raw": {}},
    ])
    res = Agent(cfg).run("what's going on?")
    assert [c["name"] for c in res["tool_calls"]] == ["client_get_state", "client_get_chat_tail"]
    assert res["content"] == "HP 100, last chat recorded."


def test_unknown_tool_is_surfaced_to_model_not_crashed():
    cfg = _cfg([
        {"content": None, "tool_calls": [_call("c1", "bogus_tool", {})], "raw": {}},
        {"content": "can't do that.", "tool_calls": [], "raw": {}},
    ])
    res = Agent(cfg).run("go!")
    # First tool result should be an error the model can read.
    assert "error" in res["tool_calls"][0]["result"]
    assert "unknown tool" in res["tool_calls"][0]["result"]["error"]


def test_max_steps_guard():
    # Model loops forever calling server_stats; agent should bail at max_steps.
    loop_call = {"content": None, "tool_calls": [_call("c1", "server_stats", {})], "raw": {}}
    cfg = _cfg([loop_call] * 10, max_steps=3)
    res = Agent(cfg).run("spin")
    assert res["steps"] == 3
    assert "max_steps" in (res["content"] or "")


def test_writes_blocked_in_read_only_mode():
    # Model asks for server_announce, but allow_writes=False so the tool
    # isn't even in the catalogue; the dispatcher returns an unknown-tool
    # error instead of performing the write.
    cfg = _cfg([
        {"content": None, "tool_calls": [_call("c1", "server_announce", {"text": "yo"})], "raw": {}},
        {"content": "write refused.", "tool_calls": [], "raw": {}},
    ], allow_writes=False)
    res = Agent(cfg).run("shout at everyone")
    assert "unknown tool" in res["tool_calls"][0]["result"]["error"]
    # The admin bridge stub recorded zero announce calls.
    assert not any(c[0] == "announce" for c in cfg.admin.calls)


def test_tool_messages_include_call_id():
    cfg = _cfg([
        {"content": None, "tool_calls": [_call("xyz", "server_stats", {})], "raw": {}},
        {"content": "done.", "tool_calls": [], "raw": {}},
    ])
    res = Agent(cfg).run("q")
    tool_msgs = [m for m in res["messages"] if m["role"] == "tool"]
    assert len(tool_msgs) == 1
    assert tool_msgs[0]["tool_call_id"] == "xyz"
    assert tool_msgs[0]["name"] == "server_stats"


def test_system_prompt_injected_once():
    cfg = _cfg([{"content": "hi", "tool_calls": [], "raw": {}}])
    res = Agent(cfg).run("hello")
    systems = [m for m in res["messages"] if m["role"] == "system"]
    assert len(systems) == 1
    assert "Chharbot" in systems[0]["content"]
