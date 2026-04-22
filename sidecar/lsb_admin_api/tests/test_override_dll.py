"""override_dll path-traversal regression. Finding #3."""
from __future__ import annotations

import os
from pathlib import Path

import pytest


def test_rejects_nul_in_path(server_mod):
    from fastapi import HTTPException
    with pytest.raises(HTTPException) as ei:
        server_mod._validate_override_dll("C:\\bad\x00path.dll")
    assert ei.value.status_code == 400


def test_rejects_missing_file(server_mod, tmp_path):
    from fastapi import HTTPException
    with pytest.raises(HTTPException):
        server_mod._validate_override_dll(str(tmp_path / "nope.dll"))


def test_rejects_non_dll_extension(server_mod, tmp_path):
    from fastapi import HTTPException
    p = tmp_path / "real.exe"
    p.write_bytes(b"MZ")
    with pytest.raises(HTTPException) as ei:
        server_mod._validate_override_dll(str(p))
    assert "must be a .dll" in ei.value.detail


def test_rejects_outside_allowlist(server_mod, tmp_path, monkeypatch):
    # Put the file outside the allow-list by pointing the allow-list at a
    # different subdir.
    inside = tmp_path / "inside"
    outside = tmp_path / "outside"
    inside.mkdir(); outside.mkdir()
    bad = outside / "ffximain.dll"
    bad.write_bytes(b"MZ")
    monkeypatch.setenv("LSB_VSYNC_ALLOWED_ROOTS", str(inside))
    from fastapi import HTTPException
    with pytest.raises(HTTPException) as ei:
        server_mod._validate_override_dll(str(bad))
    assert "allow-list" in ei.value.detail


def test_accepts_valid_dll_inside_allowlist(server_mod, tmp_path):
    good = tmp_path / "FFXiMain.dll"
    good.write_bytes(b"MZ")
    # conftest already set LSB_VSYNC_ALLOWED_ROOTS=tmp_path.
    resolved = server_mod._validate_override_dll(str(good))
    assert Path(resolved).name.lower() == "ffximain.dll"


def test_none_and_empty_string_are_allowed(server_mod):
    assert server_mod._validate_override_dll(None) is None
    assert server_mod._validate_override_dll("") is None
