"""Auth: fail-closed when no token is configured, 401 on bad token,
200 on good token. Regression for SECURITY-REVIEW.md Finding #2."""
from __future__ import annotations

import pytest


def test_health_is_public(client):
    # /health is intentionally not behind auth so operators can probe
    # without leaking the token.
    r = client.get("/health")
    assert r.status_code == 200
    assert r.json()["ok"] is True


def test_no_token_supplied_returns_401(client):
    r = client.get("/server_stats")
    assert r.status_code == 401


def test_wrong_token_returns_401(client, token):
    r = client.get("/server_stats", headers={"X-Admin-Token": "NOPE"})
    assert r.status_code == 401


def test_no_token_configured_fails_closed(no_token_server):
    """Finding #2 regression: server MUST fail closed if token file is
    missing / empty and ALLOW_NO_TOKEN is not set."""
    tc, mod = no_token_server
    assert mod.TOKEN == ""
    assert mod.ALLOW_NO_TOKEN is False
    r = tc.get("/server_stats")  # no header
    assert r.status_code == 503
    r2 = tc.get("/server_stats", headers={"X-Admin-Token": "whatever"})
    assert r2.status_code == 503
