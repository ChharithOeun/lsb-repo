"""sync.py - high-level orchestrator. Detects the retail CLIENT_VER,
diffs it against login.lua, patches if needed, and bounces login_server.

Designed to be call-safe from four places:
    - the CLI (`python -m lsb_version_sync`)
    - a FastAPI endpoint on the lsb_admin_api sidecar
    - a FastMCP tool in mcp_ffxi_admin
    - a Windows scheduled task
"""
from __future__ import annotations

import datetime as dt
import json
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Optional

from .config import Config, load_config, resolve_dll
from .patcher import (
    LoginLuaConfig,
    get_current_config,
    patch_client_ver,
)
from .reloader import RestartResult, restart_login_server
from .scanner import CandidateVersion, detect_versions


@dataclass
class SyncResult:
    ok: bool
    dry_run: bool
    dll_path: Optional[str]
    detected: Optional[str]
    previous_client_ver: Optional[str]
    new_client_ver: Optional[str]
    previous_ver_lock: Optional[int]
    new_ver_lock: Optional[int]
    restart: Optional[dict] = None
    message: str = ""
    all_candidates: list = field(default_factory=list)

    def to_json(self) -> str:
        return json.dumps(asdict(self), indent=2, default=str)


def _is_strictly_newer(new: str, prev: Optional[str]) -> bool:
    """Compare two `YYYYMMDD_R` strings lexicographically; None treats as old."""
    if prev is None or prev == "":
        return True
    # Normalize: strip any whitespace, compare as strings since YYYYMMDD
    # already sorts correctly.
    return new > prev


def _log(cfg: Config, obj: dict) -> None:
    try:
        cfg.sync_log.parent.mkdir(parents=True, exist_ok=True)
        line = json.dumps({"ts": dt.datetime.now().isoformat(timespec="seconds"), **obj})
        with cfg.sync_log.open("a", encoding="utf-8") as f:
            f.write(line + "\n")
    except OSError:
        pass  # logging is best-effort; don't crash sync over it


def sync(
    *,
    cfg: Optional[Config] = None,
    dry_run: bool = False,
    force: bool = False,
    override_dll: Optional[str] = None,
    restart: bool = True,
) -> SyncResult:
    """Detect retail version, patch login.lua if warranted, bounce login_server.

    Arguments:
        cfg         - override config; default = load_config() from env.
        dry_run     - detect + diff but DO NOT write or restart.
        force       - skip the monotonicity guard.
        override_dll - explicit FFXiMain.dll path, bypasses cfg.dll_candidates.
        restart     - bounce login_server after a successful patch.
    """
    cfg = cfg or load_config()

    dll = Path(override_dll) if override_dll else resolve_dll(cfg)
    if not dll or not dll.exists():
        result = SyncResult(
            ok=False, dry_run=dry_run, dll_path=str(dll) if dll else None,
            detected=None, previous_client_ver=None, new_client_ver=None,
            previous_ver_lock=None, new_ver_lock=None,
            message="retail FFXiMain.dll not found in candidate list",
        )
        _log(cfg, asdict(result))
        return result

    candidates = detect_versions(dll)
    best: Optional[CandidateVersion] = candidates[0] if candidates else None

    current = get_current_config(cfg.login_lua)

    if not best:
        result = SyncResult(
            ok=False, dry_run=dry_run, dll_path=str(dll),
            detected=None,
            previous_client_ver=current.client_ver,
            new_client_ver=None,
            previous_ver_lock=current.ver_lock,
            new_ver_lock=None,
            all_candidates=[asdict(c) for c in candidates],
            message="no CLIENT_VER-shaped strings found in FFXiMain.dll",
        )
        _log(cfg, asdict(result))
        return result

    target_ver = best.raw

    # Monotonicity guard: don't regress to an older version unless forced.
    if cfg.require_monotonic and not force:
        if not _is_strictly_newer(target_ver, current.client_ver):
            result = SyncResult(
                ok=True, dry_run=dry_run, dll_path=str(dll),
                detected=target_ver,
                previous_client_ver=current.client_ver,
                new_client_ver=current.client_ver,   # unchanged
                previous_ver_lock=current.ver_lock,
                new_ver_lock=current.ver_lock,
                all_candidates=[asdict(c) for c in candidates[:5]],
                message=(
                    f"skip: retail version {target_ver!r} is not newer than "
                    f"configured {current.client_ver!r}"
                ),
            )
            _log(cfg, asdict(result))
            return result

    new_ver_lock = None if cfg.keep_ver_lock else cfg.default_ver_lock

    if dry_run:
        result = SyncResult(
            ok=True, dry_run=True, dll_path=str(dll),
            detected=target_ver,
            previous_client_ver=current.client_ver,
            new_client_ver=target_ver,
            previous_ver_lock=current.ver_lock,
            new_ver_lock=new_ver_lock if new_ver_lock is not None else current.ver_lock,
            all_candidates=[asdict(c) for c in candidates[:5]],
            message="dry run: would patch CLIENT_VER",
        )
        _log(cfg, asdict(result))
        return result

    # Actually patch.
    after: LoginLuaConfig = patch_client_ver(
        cfg.login_lua,
        new_client_ver=target_ver,
        new_ver_lock=new_ver_lock,
    )

    restart_info: Optional[RestartResult] = None
    if restart:
        restart_info = restart_login_server(exe_hint=cfg.login_server_exe)

    result = SyncResult(
        ok=True, dry_run=False, dll_path=str(dll),
        detected=target_ver,
        previous_client_ver=current.client_ver,
        new_client_ver=after.client_ver,
        previous_ver_lock=current.ver_lock,
        new_ver_lock=after.ver_lock,
        all_candidates=[asdict(c) for c in candidates[:5]],
        restart=asdict(restart_info) if restart_info else None,
        message=(
            f"patched CLIENT_VER {current.client_ver!r} -> {after.client_ver!r}"
            + (f"; {restart_info.message}" if restart_info else "; no restart requested")
        ),
    )
    _log(cfg, asdict(result))
    return result
