"""Input-validation regression tests. Finding #1 (command injection via
console) and Finding #10 (length caps) from SECURITY-REVIEW.md."""
from __future__ import annotations

import pytest


# ---------- /announce ------------------------------------------------------

def test_announce_happy_path(client, hdr, server_mod):
    r = client.post("/announce", json={"text": "hello world"}, headers=hdr)
    assert r.status_code == 200
    assert server_mod._captured_console_writes == ["announce hello world"]


def test_announce_strips_newlines_into_spaces(client, hdr, server_mod):
    # Model / caller tries to smuggle a second command via \n.
    r = client.post("/announce", json={"text": "hi\nshutdown"}, headers=hdr)
    assert r.status_code == 200
    # The newline should have been replaced with a space before reaching
    # console_write - no second command should ever appear.
    writes = server_mod._captured_console_writes
    assert len(writes) == 1
    assert "\n" not in writes[0]
    assert "shutdown" in writes[0]  # text preserved, but inline, as data
    assert writes[0].startswith("announce hi ")


def test_announce_caps_length(client, hdr):
    too_long = "x" * 500
    r = client.post("/announce", json={"text": too_long}, headers=hdr)
    assert r.status_code == 400
    assert "400" in str(r.status_code)


# ---------- /tell ----------------------------------------------------------

def test_tell_rejects_bad_name(client, hdr):
    # Name with a newline should be rejected by the NAME_RE validator
    # BEFORE console_write is reached.
    r = client.post("/tell", json={"to": "Bob\nshutdown", "text": "hi"}, headers=hdr)
    assert r.status_code == 400


def test_tell_rejects_name_with_shell_chars(client, hdr):
    for bad in ("Bob;evil", "Bob|pipe", "Bob`cmd`", "../etc"):
        r = client.post("/tell", json={"to": bad, "text": "x"}, headers=hdr)
        assert r.status_code == 400, f"accepted bogus name {bad!r}"


def test_tell_accepts_valid_name(client, hdr, server_mod):
    r = client.post("/tell", json={"to": "GUESTCL1", "text": "heya"}, headers=hdr)
    assert r.status_code == 200
    writes = server_mod._captured_console_writes
    assert writes == ["sendMessage GUESTCL1 heya"]


# ---------- /teleport ------------------------------------------------------

def test_teleport_rejects_out_of_range_zone(client, hdr):
    r = client.post("/teleport", json={
        "player": "GUESTCL1", "zone": 99999,
        "x": 0, "y": 0, "z": 0,
    }, headers=hdr)
    assert r.status_code == 400


def test_teleport_rejects_non_numeric_coord(client, hdr):
    r = client.post("/teleport", json={
        "player": "GUESTCL1", "zone": 1,
        "x": "not-a-number", "y": 0, "z": 0,
    }, headers=hdr)
    # Pydantic type-coerces / rejects - 422 is fine, 400 is also fine.
    assert r.status_code in (400, 422)


def test_teleport_happy(client, hdr, server_mod):
    r = client.post("/teleport", json={
        "player": "GUESTCL1", "zone": 100,
        "x": 10.5, "y": 0.0, "z": -5.25, "rot": 128,
    }, headers=hdr)
    assert r.status_code == 200
    writes = server_mod._captured_console_writes
    assert writes
    assert writes[0].startswith("sendToZone GUESTCL1 100 ")
    assert " 128" in writes[0]


# ---------- /give_item -----------------------------------------------------

def test_give_item_rejects_out_of_range_count(client, hdr):
    r = client.post("/give_item", json={
        "player": "GUESTCL1", "item_id": 500, "count": 1000,
    }, headers=hdr)
    assert r.status_code == 400


def test_give_item_rejects_negative_id(client, hdr):
    r = client.post("/give_item", json={
        "player": "GUESTCL1", "item_id": -1, "count": 1,
    }, headers=hdr)
    assert r.status_code == 400


# ---------- console_write direct (the last-mile defence) -------------------

def test_console_write_rejects_nul():
    # This exercises the real server.console_write logic, not the test stub.
    # We call the server module's original function directly.
    import importlib, sys
    if "lsb_admin_api.server" in sys.modules:
        del sys.modules["lsb_admin_api.server"]
    # We need a fresh import that still has the original console_write.
    # The PIPE_PATH points at a non-existent pipe, so an OSError is
    # expected - what matters is the validator runs BEFORE the open call.
    import os
    os.environ.setdefault("LSB_ADMIN_ALLOW_NO_TOKEN", "1")
    mod = importlib.import_module("lsb_admin_api.server")
    from fastapi import HTTPException
    with pytest.raises(HTTPException) as ei:
        mod.console_write("announce hello\x00rm -rf /")
    assert ei.value.status_code == 400
    assert "forbidden control character" in ei.value.detail
