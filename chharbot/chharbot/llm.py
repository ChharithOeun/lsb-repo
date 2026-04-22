"""llm.py - pluggable local-LLM client.

Two backends out of the box:

  - OllamaClient: talks to /api/chat on a local Ollama daemon. Ollama's
    newer builds (0.1.33+) support OpenAI-style tool calling via the
    `tools` parameter, with responses in {message: {tool_calls: [...]}}
    shape. We use that shape directly.

  - OpenAICompatClient: any server speaking
    POST /v1/chat/completions with the OpenAI-style payload. Works for
    llama.cpp's `server` binary, LM Studio, vLLM, text-generation-inference
    with --openai, and of course OpenAI itself.

Both clients return a normalised dict:
    {"content": <str or None>, "tool_calls": [{"id", "name", "arguments"}], "raw": <server resp>}

`arguments` is kept as a JSON string so the dispatcher can validate-then-parse.
"""
from __future__ import annotations

import json
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional


class LLMError(RuntimeError):
    pass


def _post_json(url: str, body: Dict[str, Any], *, headers: Dict[str, str], timeout: float) -> Dict[str, Any]:
    data = json.dumps(body).encode("utf-8")
    req = urllib.request.Request(url, data=data, method="POST")
    for k, v in headers.items():
        req.add_header(k, v)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read()
    except urllib.error.HTTPError as e:
        body_text = e.read().decode("utf-8", errors="replace")
        raise LLMError(f"HTTP {e.code}: {body_text}")
    except urllib.error.URLError as e:
        raise LLMError(f"transport error: {e}")
    try:
        return json.loads(raw)
    except ValueError as e:
        raise LLMError(f"non-JSON response from {url}: {e}")


# ---------- base class ------------------------------------------------------

@dataclass
class LLMClient:
    base_url: str
    model: str
    timeout: float = 120.0
    api_key: str = ""

    def chat(self, messages: List[Dict[str, Any]], tools: Optional[List[Dict[str, Any]]] = None,
             temperature: float = 0.2) -> Dict[str, Any]:
        raise NotImplementedError


# ---------- Ollama ----------------------------------------------------------

class OllamaClient(LLMClient):
    """
    Talks to Ollama's /api/chat. Recent Ollama builds expose tool-calling
    through the same `tools` and `tool_calls` shape OpenAI uses; older
    builds simply ignore `tools` and return a text-only reply, which the
    agent loop treats as "final answer".

    `num_ctx` defaults to 4096 because Ollama 0.4+ otherwise inherits the
    model's full context window (131072 for Llama 3.1) and tries to
    preallocate ~24 GiB of KV cache, which fails on most workstations
    with `model requires more system memory (X GiB) than is available`.
    """

    def __init__(self, model: str = "llama3.1:8b-instruct-q4_K_M",
                 base_url: str = "http://127.0.0.1:11434", timeout: float = 120.0,
                 num_ctx: int = 4096):
        super().__init__(base_url=base_url, model=model, timeout=timeout)
        self.num_ctx = num_ctx

    @staticmethod
    def _ollamaify_messages(messages: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
        """Convert OpenAI-style assistant.tool_calls[].function.arguments
        (a JSON-encoded STRING) back into a dict, which is what Ollama's
        chat endpoint actually expects. Sending a string yields HTTP 400
        with: 'Value looks like object, but can't find closing }'.
        """
        out: List[Dict[str, Any]] = []
        for m in messages:
            if m.get("role") == "assistant" and m.get("tool_calls"):
                m2 = dict(m)
                new_calls = []
                for tc in m2["tool_calls"]:
                    tc2 = dict(tc)
                    fn = dict(tc.get("function") or {})
                    args = fn.get("arguments")
                    if isinstance(args, str):
                        try:
                            fn["arguments"] = json.loads(args) if args else {}
                        except ValueError:
                            fn["arguments"] = {}
                    tc2["function"] = fn
                    new_calls.append(tc2)
                m2["tool_calls"] = new_calls
                out.append(m2)
            else:
                out.append(m)
        return out

    def chat(self, messages, tools=None, temperature=0.2):
        body: Dict[str, Any] = {
            "model": self.model,
            "messages": self._ollamaify_messages(messages),
            "stream": False,
            "options": {
                "temperature": temperature,
                "num_ctx": self.num_ctx,
            },
        }
        if tools:
            body["tools"] = tools
        url = self.base_url.rstrip("/") + "/api/chat"
        resp = _post_json(url, body, headers={"Content-Type": "application/json"},
                          timeout=self.timeout)
        msg = resp.get("message") or {}
        calls = []
        for tc in msg.get("tool_calls", []) or []:
            # Ollama's shape: {function: {name, arguments: <dict>}}
            fn = tc.get("function") or {}
            args = fn.get("arguments")
            if isinstance(args, dict):
                args = json.dumps(args)
            calls.append({
                "id":   tc.get("id") or f"call_{int(time.time() * 1000)}",
                "name": fn.get("name"),
                "arguments": args or "{}",
            })
        return {"content": msg.get("content"), "tool_calls": calls, "raw": resp}


# ---------- OpenAI-compatible -----------------------------------------------

class OpenAICompatClient(LLMClient):
    """Works for llama.cpp server, LM Studio, vLLM, OpenAI itself, etc."""

    def __init__(self, model: str = "gpt-4o-mini",
                 base_url: str = "http://127.0.0.1:8080/v1",
                 api_key: str = "",
                 timeout: float = 120.0):
        super().__init__(base_url=base_url, model=model, timeout=timeout, api_key=api_key)

    def chat(self, messages, tools=None, temperature=0.2):
        body: Dict[str, Any] = {
            "model": self.model,
            "messages": messages,
            "temperature": temperature,
        }
        if tools:
            body["tools"] = tools
            body["tool_choice"] = "auto"
        url = self.base_url.rstrip("/") + "/chat/completions"
        headers = {"Content-Type": "application/json"}
        if self.api_key:
            headers["Authorization"] = f"Bearer {self.api_key}"
        resp = _post_json(url, body, headers=headers, timeout=self.timeout)
        choice = (resp.get("choices") or [{}])[0]
        msg = choice.get("message") or {}
        calls = []
        for tc in msg.get("tool_calls", []) or []:
            fn = tc.get("function") or {}
            calls.append({
                "id":   tc.get("id") or f"call_{int(time.time() * 1000)}",
                "name": fn.get("name"),
                "arguments": fn.get("arguments") or "{}",
            })
        return {"content": msg.get("content"), "tool_calls": calls, "raw": resp}
