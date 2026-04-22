"""reloader.py - bounce LSB's login_server so a patched CLIENT_VER takes
effect. `login_server` reads `settings/login.lua` only at startup, so a
config change without a restart is a no-op.

We deliberately don't touch `map_server.exe`: CLIENT_VER lives entirely
in login.cpp's handshake path. Keeping the map process up means players
already in-game aren't kicked by a version resync.
"""
from __future__ import annotations

import os
import shlex
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, List, Optional


@dataclass
class RestartResult:
    stopped_pid: Optional[int]
    started_pid: Optional[int]
    exe_path: Optional[Path]
    message: str

    @property
    def ok(self) -> bool:
        return self.started_pid is not None


def _iter_login_server_procs() -> Iterable[tuple[int, Optional[Path]]]:
    """Yield (pid, exe_path?) for every running login_server.exe.

    Uses psutil if available; falls back to Windows tasklist parsing
    otherwise so the module doesn't hard-require a third-party dep.
    """
    try:
        import psutil  # type: ignore
    except ImportError:
        psutil = None

    if psutil is not None:
        for p in psutil.process_iter(attrs=["pid", "name", "exe"]):
            name = (p.info.get("name") or "").lower()
            if name == "login_server.exe" or name == "login_server":
                yield p.info["pid"], Path(p.info["exe"]) if p.info.get("exe") else None
        return

    # Fallback: tasklist -FI IMAGENAME eq login_server.exe -V
    if os.name != "nt":
        return
    try:
        out = subprocess.check_output(
            ["tasklist", "/FI", "IMAGENAME eq login_server.exe", "/FO", "CSV", "/NH"],
            stderr=subprocess.STDOUT, text=True,
        )
    except subprocess.CalledProcessError:
        return
    for line in out.splitlines():
        line = line.strip()
        if not line or line.startswith('"INFO'):
            continue
        # "login_server.exe","1234","Console","1","12,345 K"
        parts = [c.strip().strip('"') for c in line.split(",")]
        if len(parts) >= 2 and parts[0].lower().startswith("login_server"):
            try:
                yield int(parts[1]), None
            except ValueError:
                pass


def restart_login_server(
    exe_hint: Optional[str | Path] = None,
    *,
    stop_timeout: float = 10.0,
) -> RestartResult:
    """Stop every running login_server.exe and relaunch one.

    `exe_hint` is the known-good executable path. If omitted the function
    tries to discover the path from a running process (psutil); if that
    can't resolve it, caller must pass `exe_hint` explicitly.
    """
    stopped_pid: Optional[int] = None
    discovered_exe: Optional[Path] = None
    cwd: Optional[Path] = None

    for pid, exe in _iter_login_server_procs():
        stopped_pid = pid
        discovered_exe = discovered_exe or exe
        try:
            if os.name == "nt":
                subprocess.run(["taskkill", "/PID", str(pid), "/F"], check=False,
                               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            else:
                os.kill(pid, 15)
        except OSError:
            pass

    # Wait until stopped.
    deadline = time.time() + stop_timeout
    while time.time() < deadline:
        if not any(True for _ in _iter_login_server_procs()):
            break
        time.sleep(0.25)

    exe: Optional[Path] = Path(exe_hint) if exe_hint else discovered_exe
    if exe is None:
        return RestartResult(
            stopped_pid=stopped_pid, started_pid=None, exe_path=None,
            message="login_server.exe not found (pass exe_hint explicitly)",
        )

    # Harden against process-hijack: the exe we're about to launch must
    # actually be a real file named `login_server.exe` (or `login_server`
    # on POSIX), and must resolve without following a symlink to somewhere
    # surprising. Callers sending us a bogus `exe_hint` don't get to turn
    # this function into a generic `subprocess.Popen` wrapper.
    try:
        exe_resolved = exe.resolve(strict=True)
    except (OSError, FileNotFoundError):
        return RestartResult(
            stopped_pid=stopped_pid, started_pid=None, exe_path=None,
            message=f"exe_hint not found: {exe}",
        )
    if exe.is_symlink() and exe_resolved != exe.readlink().resolve():
        return RestartResult(
            stopped_pid=stopped_pid, started_pid=None, exe_path=exe,
            message="exe_hint is a symlink; refusing to launch",
        )
    basename = exe_resolved.name.lower()
    if basename not in ("login_server.exe", "login_server"):
        return RestartResult(
            stopped_pid=stopped_pid, started_pid=None, exe_path=exe_resolved,
            message=f"exe_hint must be login_server[.exe], got {basename!r}",
        )
    exe = exe_resolved
    cwd = exe.parent

    kwargs = {}
    if os.name == "nt":
        # Start detached so the parent can exit (used from MCP calls).
        DETACHED_PROCESS = 0x00000008
        CREATE_NEW_PROCESS_GROUP = 0x00000200
        kwargs["creationflags"] = DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP
    new = subprocess.Popen([str(exe)], cwd=str(cwd), close_fds=True, **kwargs)
    return RestartResult(
        stopped_pid=stopped_pid, started_pid=new.pid, exe_path=exe,
        message=f"restarted login_server as pid {new.pid}",
    )
