"""config.py - defaults for the version-sync subsystem, overridable via
environment variables or a YAML-less dict passed to sync().

Everything is a single source of truth here so the CLI, the MCP tools,
the scheduled task, and the sidecar endpoint all behave consistently.
"""
from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path
from typing import List, Optional


#
# Scanner targets, ordered by preference.
#
# Despite the historical name "DLL_CANDIDATES", the scanner is content-
# agnostic (it mmaps and grep's for YYYYMMDD_R-shaped byte runs), so
# ANY file that contains retail patch stamps works. On modern retail
# installs FFXiMain.dll NO LONGER contains the stamp string - SE moved
# it out of the binary sometime in the 30xx-era builds, so a pure
# FFXiMain scan returns zero candidates (see chharbot/bin/detect_probe3
# findings, 2026-04-21). The canonical place the stamp lives now is the
# `patch2.cfg` manifest next to FINAL FANTASY XI, which lists every
# historical patch date. The scanner sorts newest-first so picking the
# latest entry == picking the retail client's current version.
#
# We keep FFXiMain.dll in the fallback list for older installs and for
# the unit tests that rely on it; if it ever starts shipping the stamp
# again, the scanner will happily use it.
#
DEFAULT_DLL_CANDIDATES: List[str] = [
    # PRIMARY: POL patch manifest - the modern source of retail CLIENT_VER.
    r"C:\Program Files (x86)\Steam\steamapps\common\FFXINA\SquareEnix\FINAL FANTASY XI\patch2.cfg",
    r"C:\Program Files (x86)\SquareEnix\FINAL FANTASY XI\patch2.cfg",
    r"C:\Program Files\SquareEnix\FINAL FANTASY XI\patch2.cfg",
    r"D:\Steam\steamapps\common\FFXINA\SquareEnix\FINAL FANTASY XI\patch2.cfg",
    r"F:\ffxi\client\FINAL FANTASY XI\patch2.cfg",
    # FALLBACK: the old FFXiMain.dll locations. Kept so if SE ever puts
    # the stamp back we still find it, and so existing deployments don't
    # silently regress if patch2.cfg is somehow missing.
    r"C:\Program Files (x86)\Steam\steamapps\common\FFXINA\SquareEnix\FINAL FANTASY XI\FFXiMain.dll",
    r"C:\Program Files (x86)\SquareEnix\FINAL FANTASY XI\FFXiMain.dll",
    r"C:\Program Files\SquareEnix\FINAL FANTASY XI\FFXiMain.dll",
    r"D:\Steam\steamapps\common\FFXINA\SquareEnix\FINAL FANTASY XI\FFXiMain.dll",
]


@dataclass
class Config:
    dll_candidates: List[str]
    login_lua: Path
    login_server_exe: Optional[Path]
    sync_log: Path
    # When True, only update CLIENT_VER and leave VER_LOCK alone. Default
    # is True because auto-match means you *want* strict matching - the
    # whole point is that the config now tracks retail automatically.
    keep_ver_lock: bool = True
    # If keep_ver_lock is False, set VER_LOCK to this value during sync.
    default_ver_lock: int = 2
    # Don't touch login.lua unless the retail version is strictly newer
    # than what's currently configured. Prevents downgrades if a stale
    # FFXiMain.dll is accidentally scanned.
    require_monotonic: bool = True


def load_config() -> Config:
    return Config(
        dll_candidates=[
            s for s in (
                os.environ.get("LSB_VSYNC_DLL", "").split(os.pathsep)
                if os.environ.get("LSB_VSYNC_DLL") else []
            ) if s
        ] or DEFAULT_DLL_CANDIDATES,
        login_lua=Path(os.environ.get(
            "LSB_LOGIN_LUA",
            r"F:\ffxi\server\settings\login.lua",
        )),
        login_server_exe=Path(os.environ["LSB_LOGIN_EXE"]) if os.environ.get("LSB_LOGIN_EXE") else None,
        sync_log=Path(os.environ.get("LSB_VSYNC_LOG", r"F:\ffxi\deploy\lsb-version-sync.log")),
        keep_ver_lock=os.environ.get("LSB_VSYNC_KEEP_VER_LOCK", "1") != "0",
        default_ver_lock=int(os.environ.get("LSB_VSYNC_DEFAULT_VER_LOCK", "2")),
        require_monotonic=os.environ.get("LSB_VSYNC_MONOTONIC", "1") != "0",
    )


def resolve_dll(cfg: Config) -> Optional[Path]:
    for cand in cfg.dll_candidates:
        p = Path(cand)
        if p.exists():
            return p
    return None
