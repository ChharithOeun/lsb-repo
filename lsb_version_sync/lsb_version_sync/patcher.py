"""patcher.py - read and rewrite LSB's login.lua, preserving everything
except `CLIENT_VER` and (optionally) `VER_LOCK`. Atomic via a temp file +
rename, with a timestamped backup beside the original.

login.lua is a plain Lua table; we don't parse it as Lua (LSB uses the
same regex-friendly key-value layout as the upstream project). This
module only edits the two fields we care about and preserves whitespace,
comments, and ordering elsewhere.
"""
from __future__ import annotations

import datetime as dt
import os
import re
from dataclasses import dataclass
from pathlib import Path
from typing import Optional


CLIENT_VER_PAT = re.compile(
    r"""(?P<lead>^\s*CLIENT_VER\s*=\s*['"])(?P<val>[^'"]*)(?P<tail>['"]\s*,?.*)$""",
    re.MULTILINE,
)
VER_LOCK_PAT = re.compile(
    r"""(?P<lead>^\s*VER_LOCK\s*=\s*)(?P<val>\d+)(?P<tail>\s*,?.*)$""",
    re.MULTILINE,
)


@dataclass
class LoginLuaConfig:
    path: Path
    client_ver: Optional[str]
    ver_lock: Optional[int]

    @property
    def summary(self) -> str:
        cv = self.client_ver if self.client_ver else "(missing)"
        vl = self.ver_lock if self.ver_lock is not None else "(missing)"
        return f"CLIENT_VER={cv!r}  VER_LOCK={vl}"


def get_current_config(path: str | Path) -> LoginLuaConfig:
    p = Path(path)
    if not p.exists():
        raise FileNotFoundError(f"login.lua not found: {p}")
    txt = p.read_text(encoding="utf-8", errors="replace")

    cv = None
    m = CLIENT_VER_PAT.search(txt)
    if m:
        cv = m.group("val")

    vl = None
    m2 = VER_LOCK_PAT.search(txt)
    if m2:
        try:
            vl = int(m2.group("val"))
        except ValueError:
            vl = None

    return LoginLuaConfig(path=p, client_ver=cv, ver_lock=vl)


def _refuse_symlinks(path: Path) -> None:
    """Belt-and-braces: we only want to edit *regular* files in-place.

    If a symlink (or hard link pointing at somewhere unexpected) appears
    where login.lua should be, refuse to proceed. Catches the classic
    TOCTOU symlink-swap attack on the target directory.
    """
    if path.is_symlink():
        raise PermissionError(f"{path} is a symlink; refusing to patch")
    # Resolve both the directory and basename; if they disagree with the
    # caller's intent the write is aborted. A shared-hosting attacker who
    # replaces login.lua between our read and our write wins the race
    # regardless, but we at least make it non-trivial.
    parent_real = path.parent.resolve(strict=True)
    if path.name != path.resolve().name:
        raise PermissionError(f"{path} resolves to a different name; refusing")


def _atomic_write(path: Path, content: str) -> None:
    _refuse_symlinks(path)
    # Use a nonce-y temp name so two concurrent runs don't clobber each
    # other, and keep it in the same directory so os.replace is a rename
    # (atomic on both NTFS and POSIX).
    tmp = path.with_suffix(path.suffix + f".tmp.{os.getpid()}")
    tmp.write_text(content, encoding="utf-8")
    os.replace(tmp, path)


def _backup(path: Path) -> Path:
    _refuse_symlinks(path)
    stamp = dt.datetime.now().strftime("%Y%m%d-%H%M%S")
    bak = path.with_suffix(path.suffix + f".ver-sync-bak.{stamp}")
    bak.write_bytes(path.read_bytes())
    return bak


def patch_client_ver(
    path: str | Path,
    *,
    new_client_ver: Optional[str] = None,
    new_ver_lock: Optional[int] = None,
    make_backup: bool = True,
) -> LoginLuaConfig:
    """Rewrite login.lua with a new CLIENT_VER and/or VER_LOCK.

    Returns the *new* LoginLuaConfig after the write. If no change is
    required, no write is performed and no backup is created.
    """
    p = Path(path)
    before = get_current_config(p)

    if new_client_ver is None and new_ver_lock is None:
        return before

    change_needed = False
    if new_client_ver is not None and new_client_ver != before.client_ver:
        change_needed = True
    if new_ver_lock is not None and new_ver_lock != before.ver_lock:
        change_needed = True
    if not change_needed:
        return before

    txt = p.read_text(encoding="utf-8")

    if new_client_ver is not None:
        def _sub_cv(m: re.Match) -> str:
            return f"{m.group('lead')}{new_client_ver}{m.group('tail')}"
        new_txt, n = CLIENT_VER_PAT.subn(_sub_cv, txt, count=1)
        if n == 0:
            # Append if missing entirely.
            suffix = f"\nCLIENT_VER = '{new_client_ver}',\n"
            new_txt = txt.rstrip() + suffix
        txt = new_txt

    if new_ver_lock is not None:
        def _sub_vl(m: re.Match) -> str:
            return f"{m.group('lead')}{new_ver_lock}{m.group('tail')}"
        new_txt, n = VER_LOCK_PAT.subn(_sub_vl, txt, count=1)
        if n == 0:
            new_txt = txt.rstrip() + f"\nVER_LOCK = {new_ver_lock},\n"
        txt = new_txt

    if make_backup:
        _backup(p)
    _atomic_write(p, txt)
    return get_current_config(p)
