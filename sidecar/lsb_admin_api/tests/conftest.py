"""Shared fixtures for the sidecar tests.

The sidecar reads `LSB_ADMIN_TOKEN_FILE` at import time, and `console_write`
opens a real named pipe. Both are awkward for unit tests, so we:

  1. Write a token file to a tmp location BEFORE importing the server module.
  2. Monkeypatch `console_write` on the freshly-imported module to capture
     whatever commands would have been sent to map_server.exe.

These run offline (no real uvicorn, no real pipe).
"""
from __future__ import annotations

import importlib
import os
import sys
from pathlib import Path
from typing import List

import pytest

# Make the sidecar package importable without installing it.
_SIDECAR_ROOT = Path(__file__).resolve().parents[2]  # <repo>/sidecar
sys.path.insert(0, str(_SIDECAR_ROOT))


@pytest.fixture
def token(tmp_path: Path) -> str:
    tok = "test-token-xyz"
    p = tmp_path / ".lsb_admin_token"
    p.write_text(tok, encoding="utf-8")
    os.environ["LSB_ADMIN_TOKEN_FILE"] = str(p)
    os.environ["LSB_ADMIN_ALLOW_NO_TOKEN"] = "0"
    # Lock DLL allow-list to the tmp dir so the override-dll tests are sane.
    os.environ["LSB_VSYNC_ALLOWED_ROOTS"] = str(tmp_path)
    return tok


@pytest.fixture
def server_mod(token):
    # Re-import so the module picks up our tmp token file.
    if "lsb_admin_api.server" in sys.modules:
        del sys.modules["lsb_admin_api.server"]
    mod = importlib.import_module("lsb_admin_api.server")
    # Capture console_write calls instead of opening a real pipe.
    mod._captured_console_writes: List[str] = []
    _original = mod.console_write
    def _fake_console_write(cmd):
        # Preserve the CR/LF/NUL rejection the real function enforces.
        if any(c in cmd for c in ("\r", "\n", "\x00")):
            from fastapi import HTTPException
            raise HTTPException(status_code=400,
                                detail="console command contains forbidden control character")
        if len(cmd) > 1024:
            from fastapi import HTTPException
            raise HTTPException(status_code=400, detail="console command too long")
        mod._captured_console_writes.append(cmd)
    mod.console_write = _fake_console_write
    yield mod
    mod.console_write = _original


@pytest.fixture
def client(server_mod):
    from fastapi.testclient import TestClient
    return TestClient(server_mod.app)


@pytest.fixture
def hdr(token):
    return {"X-Admin-Token": token}


@pytest.fixture
def no_token_server(tmp_path, monkeypatch):
    """Server imported with ZERO token configured and ALLOW_NO_TOKEN=0.
    Every authed endpoint should return 503."""
    # Point at a non-existent file.
    os.environ["LSB_ADMIN_TOKEN_FILE"] = str(tmp_path / "does-not-exist")
    os.environ["LSB_ADMIN_ALLOW_NO_TOKEN"] = "0"
    os.environ["LSB_VSYNC_ALLOWED_ROOTS"] = str(tmp_path)
    if "lsb_admin_api.server" in sys.modules:
        del sys.modules["lsb_admin_api.server"]
    mod = importlib.import_module("lsb_admin_api.server")
    from fastapi.testclient import TestClient
    return TestClient(mod.app), mod
