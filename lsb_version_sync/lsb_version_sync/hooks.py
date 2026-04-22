"""hooks.py - integration glue for the version-sync subsystem.

Three hooks:

    - pre_login_start_hook()   called by an operator's login_server
                               launcher. If a new retail version is
                               detected it patches + continues.
    - scheduled_run()          the entry point for the Windows scheduled
                               task; sleeps-safe, idempotent.
    - print_status()           human-readable summary for the CLI
                               `status` subcommand.
"""
from __future__ import annotations

import json
from typing import Optional

from .config import Config, load_config, resolve_dll
from .patcher import get_current_config
from .scanner import detect_versions
from .sync import SyncResult, sync


def print_status(cfg: Optional[Config] = None) -> str:
    cfg = cfg or load_config()
    dll = resolve_dll(cfg)
    current = None
    try:
        current = get_current_config(cfg.login_lua)
    except FileNotFoundError:
        pass
    best = None
    if dll and dll.exists():
        xs = detect_versions(dll)
        best = xs[0] if xs else None

    lines = [
        "=== lsb_version_sync status ===",
        f"  login.lua          : {cfg.login_lua}",
        f"  configured         : {current.summary if current else '(missing)'}",
        f"  retail FFXiMain.dll: {dll or '(not found)'}",
        f"  detected retail    : {best.raw if best else '(none)'}",
    ]
    if current and best:
        if current.client_ver == best.raw:
            lines.append("  status             : UP TO DATE")
        elif best.raw > (current.client_ver or ""):
            lines.append("  status             : DRIFT - retail is newer; run `sync` to match")
        else:
            lines.append("  status             : configured version is newer than retail (odd)")
    return "\n".join(lines)


def scheduled_run() -> SyncResult:
    """Entry point for the Windows scheduled task (daily/hourly).

    Non-interactive: runs a real sync, never a dry run, logs to the
    sync log file. Never raises - we swallow exceptions to keep the
    task's exit code stable.
    """
    try:
        return sync()
    except Exception as exc:  # noqa: BLE001
        from dataclasses import asdict
        from .sync import SyncResult
        return SyncResult(
            ok=False, dry_run=False, dll_path=None,
            detected=None, previous_client_ver=None, new_client_ver=None,
            previous_ver_lock=None, new_ver_lock=None,
            message=f"scheduled_run crashed: {exc!r}",
        )


def pre_login_start_hook() -> SyncResult:
    """Call from your login_server launcher BEFORE the exe starts.

    Ensures the config is in sync with whatever retail client is on disk
    at startup time, so the first player to connect after a retail patch
    doesn't hit FFXI-3331.
    """
    return sync(restart=False)  # the launcher will start login_server itself
