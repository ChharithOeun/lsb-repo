"""Tests for patcher.py - safe edits to login.lua."""
from __future__ import annotations

from pathlib import Path

import pytest

from lsb_version_sync.patcher import (
    get_current_config,
    patch_client_ver,
)


SAMPLE = """-- login.lua --
login =
{
    -- Connection banner, etc.
    LOGIN_OPENING_SCREEN = 'Welcome',
    CLIENT_VER = '30260203_0',    -- date-stamped build
    VER_LOCK   = 2,               -- 0=off 1=strict 2=GE
    MAX_USERS  = 128,
    -- end
}
return login
"""


def _mklogin(tmp_path: Path, body: str = SAMPLE) -> Path:
    p = tmp_path / "login.lua"
    p.write_text(body, encoding="utf-8")
    return p


def test_read_current_config(tmp_path):
    p = _mklogin(tmp_path)
    cfg = get_current_config(p)
    assert cfg.client_ver == "30260203_0"
    assert cfg.ver_lock == 2


def test_patch_new_client_ver_preserves_other_lines(tmp_path):
    p = _mklogin(tmp_path)
    after = patch_client_ver(p, new_client_ver="30260401_0")
    txt = p.read_text(encoding="utf-8")
    assert after.client_ver == "30260401_0"
    assert "MAX_USERS" in txt
    assert "LOGIN_OPENING_SCREEN" in txt
    # Comment on the CLIENT_VER line is preserved.
    assert "date-stamped build" in txt


def test_patch_creates_backup(tmp_path):
    p = _mklogin(tmp_path)
    patch_client_ver(p, new_client_ver="30260401_0")
    backups = list(tmp_path.glob("login.lua.ver-sync-bak.*"))
    assert len(backups) == 1
    assert "CLIENT_VER = '30260203_0'" in backups[0].read_text(encoding="utf-8")


def test_patch_ver_lock(tmp_path):
    p = _mklogin(tmp_path)
    after = patch_client_ver(p, new_ver_lock=0)
    assert after.ver_lock == 0
    assert "VER_LOCK   = 0" in p.read_text(encoding="utf-8") or \
           "VER_LOCK = 0" in p.read_text(encoding="utf-8")


def test_no_change_no_backup(tmp_path):
    p = _mklogin(tmp_path)
    patch_client_ver(p, new_client_ver="30260203_0")  # same as current
    backups = list(tmp_path.glob("login.lua.ver-sync-bak.*"))
    assert not backups


def test_appends_missing_fields(tmp_path):
    p = tmp_path / "login.lua"
    p.write_text("login = { FOO = 1 }\n", encoding="utf-8")
    after = patch_client_ver(p, new_client_ver="30260203_0", new_ver_lock=2)
    assert after.client_ver == "30260203_0"
    assert after.ver_lock == 2


def test_missing_file_raises(tmp_path):
    with pytest.raises(FileNotFoundError):
        get_current_config(tmp_path / "nope.lua")
