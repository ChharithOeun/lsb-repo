"""lsb_version_sync - detect the retail FFXI client version and auto-patch
it into LandSandBoat's login.lua so FFXI-3331 never recurs.

Three concerns kept separate so they can be composed (CLI, scheduled task,
HTTP sidecar endpoint, MCP tool, unit tests):

    scanner.py   - read FFXiMain.dll, find all plausible CLIENT_VER strings
    patcher.py   - read/modify login.lua atomically, with a backup
    reloader.py  - bounce LSB's login_server so the change takes effect
    sync.py      - the high-level "one-shot sync" flow that ties them together
    hooks.py     - optional integration points (startup hook, scheduled task)

Public surface (stable):

    from lsb_version_sync import sync, detect_versions, get_current_config

    versions = detect_versions("C:/.../FFXiMain.dll")
    config   = get_current_config("F:/ffxi/server/settings/login.lua")
    result   = sync(dry_run=False)   # detect -> patch -> reload
"""
from .scanner  import detect_versions, CandidateVersion
from .patcher  import get_current_config, patch_client_ver, LoginLuaConfig
from .reloader import restart_login_server
from .sync     import sync, SyncResult

__all__ = [
    "detect_versions", "CandidateVersion",
    "get_current_config", "patch_client_ver", "LoginLuaConfig",
    "restart_login_server",
    "sync", "SyncResult",
]

__version__ = "0.1.0"
