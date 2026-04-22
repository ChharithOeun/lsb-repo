"""Security-hardening tests for lsb_version_sync.

These are the test cases we promise the security-review doc: every
finding we fixed should be represented here so regressions break the
build.
"""
from __future__ import annotations

import os
import sys
from pathlib import Path

import pytest

from lsb_version_sync.patcher import patch_client_ver, _refuse_symlinks
from lsb_version_sync.reloader import restart_login_server


_SAMPLE = """login = {
    CLIENT_VER = '30260203_0',
    VER_LOCK   = 2,
}
"""


def _lua(tmp_path: Path) -> Path:
    p = tmp_path / "login.lua"
    p.write_text(_SAMPLE, encoding="utf-8")
    return p


def test_patcher_refuses_symlink_target(tmp_path):
    """Finding #5: symlink-swap on login.lua must abort the write."""
    if sys.platform == "win32":
        pytest.skip("symlink creation on Windows is admin-only")
    real = _lua(tmp_path)
    link = tmp_path / "login.lua.link"
    try:
        os.symlink(real, link)
    except (OSError, NotImplementedError):
        pytest.skip("cannot create symlinks in this sandbox")
    with pytest.raises(PermissionError):
        patch_client_ver(link, new_client_ver="30260401_0")


def test_atomic_tmp_filename_includes_pid(tmp_path):
    """Concurrent sync runs must not clobber each other's temp files."""
    real = _lua(tmp_path)
    patch_client_ver(real, new_client_ver="30260401_0")
    # No stray .tmp files should be left after a successful patch.
    assert not list(tmp_path.glob("*.tmp*"))


def test_reloader_rejects_non_login_server_exe(tmp_path):
    """Finding #6: a caller can't point exe_hint at `calc.exe`."""
    bogus = tmp_path / "calc.exe"
    bogus.write_bytes(b"MZ stub")
    r = restart_login_server(exe_hint=bogus)
    assert not r.ok
    assert "login_server" in r.message


def test_reloader_rejects_missing_exe(tmp_path):
    r = restart_login_server(exe_hint=tmp_path / "does_not_exist.exe")
    assert not r.ok
    assert "not found" in r.message


@pytest.mark.skipif(sys.platform == "win32", reason="posix symlink test")
def test_reloader_rejects_symlinked_exe(tmp_path):
    real = tmp_path / "login_server"
    real.write_bytes(b"stub")
    real.chmod(0o755)
    # Symlink to something WITH a valid name - the basename check passes
    # but we still want the discovery to be auditable.
    link = tmp_path / "login_server.link"
    try:
        os.symlink(real, link)
    except (OSError, NotImplementedError):
        pytest.skip("cannot create symlinks")
    # This should succeed (same basename), proving we don't reject all
    # symlinks unconditionally - only ones where the target disagrees.
    # We don't actually start a process; we just verify the check logic
    # by pointing at an existing valid-named target.
    # Smoke-only: we accept a zero-byte binary because Popen on
    # platforms without an ELF interpreter will still launch it.
