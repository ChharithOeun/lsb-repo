"""Integration tests for the sync() orchestrator using a synthetic
FFXiMain.dll (just a bytes blob) and a temp login.lua.
"""
from __future__ import annotations

from pathlib import Path

from lsb_version_sync.config import Config
from lsb_version_sync.sync import sync


SAMPLE_LUA = """login = {
    CLIENT_VER = '30260203_0',
    VER_LOCK   = 2,
}
"""


def _fake_dll(p: Path, version: str) -> Path:
    # Padding bytes + version string in ASCII + more padding.
    p.write_bytes(b"\x00" * 64 + b"retail " + version.encode("ascii") + b"\x00" * 64)
    return p


def _cfg(tmp_path: Path, dll: Path, lua: Path) -> Config:
    return Config(
        dll_candidates=[str(dll)],
        login_lua=lua,
        login_server_exe=None,
        sync_log=tmp_path / "sync.log",
        keep_ver_lock=True,
        default_ver_lock=2,
        require_monotonic=True,
    )


def test_dry_run_reports_drift_without_writing(tmp_path):
    dll = _fake_dll(tmp_path / "FFXiMain.dll", "30260401_0")
    lua = tmp_path / "login.lua"; lua.write_text(SAMPLE_LUA)

    cfg = _cfg(tmp_path, dll, lua)
    r = sync(cfg=cfg, dry_run=True, restart=False)

    assert r.ok
    assert r.dry_run
    assert r.detected == "30260401_0"
    assert r.previous_client_ver == "30260203_0"
    assert r.new_client_ver == "30260401_0"
    # File should be untouched.
    assert "30260203_0" in lua.read_text()


def test_sync_patches_when_retail_is_newer(tmp_path):
    dll = _fake_dll(tmp_path / "FFXiMain.dll", "30260401_0")
    lua = tmp_path / "login.lua"; lua.write_text(SAMPLE_LUA)

    cfg = _cfg(tmp_path, dll, lua)
    r = sync(cfg=cfg, dry_run=False, restart=False)

    assert r.ok
    assert r.new_client_ver == "30260401_0"
    assert "30260401_0" in lua.read_text()


_NEWER_LUA = """login = {
    CLIENT_VER = '30260705_1',
    VER_LOCK   = 2,
}
"""


def test_monotonic_guard_skips_downgrade(tmp_path):
    # DLL has OLD version; login.lua has newer.
    dll = _fake_dll(tmp_path / "FFXiMain.dll", "30260101_0")
    lua = tmp_path / "login.lua"
    lua.write_text(_NEWER_LUA)

    cfg = _cfg(tmp_path, dll, lua)
    r = sync(cfg=cfg, dry_run=False, restart=False)

    assert r.ok                                # skip is a non-error
    assert r.new_client_ver == "30260705_1"    # unchanged
    assert "30260705_1" in lua.read_text()
    assert "skip" in r.message


def test_force_overrides_monotonic(tmp_path):
    dll = _fake_dll(tmp_path / "FFXiMain.dll", "30260101_0")
    lua = tmp_path / "login.lua"
    lua.write_text(_NEWER_LUA)

    cfg = _cfg(tmp_path, dll, lua)
    r = sync(cfg=cfg, dry_run=False, force=True, restart=False)

    assert r.ok
    assert r.new_client_ver == "30260101_0"
    assert "30260101_0" in lua.read_text()


def test_missing_dll_returns_error(tmp_path):
    lua = tmp_path / "login.lua"; lua.write_text(SAMPLE_LUA)
    cfg = _cfg(tmp_path, tmp_path / "missing.dll", lua)
    r = sync(cfg=cfg, dry_run=False, restart=False)
    assert not r.ok
    assert "not found" in r.message


def test_sync_log_is_written(tmp_path):
    dll = _fake_dll(tmp_path / "FFXiMain.dll", "30260401_0")
    lua = tmp_path / "login.lua"; lua.write_text(SAMPLE_LUA)
    cfg = _cfg(tmp_path, dll, lua)
    sync(cfg=cfg, dry_run=True, restart=False)
    assert cfg.sync_log.exists()
    assert "detected" in cfg.sync_log.read_text()
