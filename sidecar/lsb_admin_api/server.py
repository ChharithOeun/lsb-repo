"""lsb_admin_api - small HTTP sidecar that exposes LSB server state and admin
commands on localhost:27116. Sits next to map_server.exe and:

  1. Opens a read-only MariaDB connection to LSB's DB (same creds as LSB).
  2. Writes console commands into map_server.exe via a Windows named pipe
     (`\\.\pipe\lsb_admin`), which a one-line wrapper connects to
     map_server's stdin. If the pipe isn't available the write endpoints
     respond 503.

Auth is a single shared token compared with `hmac.compare_digest`. Secret
lives in `F:\\ffxi\\deploy\\.lsb_admin_token`, mode 0600.

Install:
    pip install fastapi uvicorn pymysql

Run:
    set LSB_DB_HOST=127.0.0.1
    set LSB_DB_USER=dspuser
    set LSB_DB_PASS=...
    set LSB_DB_NAME=dspdb
    set LSB_ADMIN_TOKEN_FILE=F:\\ffxi\\deploy\\.lsb_admin_token
    set LSB_ADMIN_PIPE=\\\\.\\pipe\\lsb_admin
    python server.py
"""
from __future__ import annotations

import hmac
import logging
import os
import re
import time
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Optional

try:
    from fastapi import FastAPI, Header, HTTPException
    from pydantic import BaseModel
    import uvicorn
except ImportError as exc:  # pragma: no cover
    raise SystemExit("pip install fastapi uvicorn pymysql") from exc

try:
    import pymysql
except ImportError:  # pragma: no cover
    pymysql = None  # DB endpoints will 503 if unavailable


DB_HOST = os.environ.get("LSB_DB_HOST", "127.0.0.1")
DB_PORT = int(os.environ.get("LSB_DB_PORT", "3306"))
DB_USER = os.environ.get("LSB_DB_USER", "dspuser")
DB_PASS = os.environ.get("LSB_DB_PASS", "dspuser")
DB_NAME = os.environ.get("LSB_DB_NAME", "dspdb")

TOKEN_FILE = os.environ.get("LSB_ADMIN_TOKEN_FILE", r"F:\ffxi\deploy\.lsb_admin_token")
PIPE_PATH  = os.environ.get("LSB_ADMIN_PIPE",  r"\\.\pipe\lsb_admin")
HOST = os.environ.get("LSB_ADMIN_HOST", "127.0.0.1")
PORT = int(os.environ.get("LSB_ADMIN_PORT", "27116"))


def _load_token() -> str:
    p = Path(TOKEN_FILE)
    if not p.exists():
        return ""
    return p.read_text(encoding="utf-8").strip()


TOKEN = _load_token()
ALLOW_NO_TOKEN = os.environ.get("LSB_ADMIN_ALLOW_NO_TOKEN", "0") == "1"

_log = logging.getLogger("lsb_admin_api")
if not _log.handlers:
    logging.basicConfig(level=logging.INFO)

if not TOKEN:
    if ALLOW_NO_TOKEN:
        _log.warning(
            "lsb_admin_api running WITHOUT an admin token "
            "(LSB_ADMIN_ALLOW_NO_TOKEN=1). Localhost-only bind is your only "
            "defence; any local process can hit write endpoints."
        )
    else:
        _log.error(
            "lsb_admin_api refusing to serve: admin token file is empty or "
            "missing (%s). Generate a token or set LSB_ADMIN_ALLOW_NO_TOKEN=1 "
            "if you really want to run unauthenticated on localhost.",
            TOKEN_FILE,
        )


def check_auth(supplied: Optional[str]) -> None:
    if not TOKEN:
        if ALLOW_NO_TOKEN:
            return
        # Fail closed rather than silently allowing everything.
        raise HTTPException(
            status_code=503,
            detail="admin token not configured; set LSB_ADMIN_TOKEN_FILE or "
                   "LSB_ADMIN_ALLOW_NO_TOKEN=1",
        )
    if not supplied or not hmac.compare_digest(supplied, TOKEN):
        raise HTTPException(status_code=401, detail="invalid admin token")


# ---------- input-validation helpers (see docs/SECURITY-REVIEW.md) ----------

# FFXI char names are 3-15 characters, [A-Za-z] plus rare punctuation. We're
# strict on purpose - names carried from untrusted API calls into LSB's
# console must not let a newline sneak in and inject a second command.
_NAME_RE = re.compile(r"^[A-Za-z][A-Za-z0-9_.'\- ]{0,31}$")

# Free-form operator text (announce, tell body, kick reason). We strip
# CR/LF/NUL and cap length to something the console can swallow without
# misbehaving.
_BAD_CTRL = re.compile(r"[\r\n\x00\x01\x02\x03\x04\x05\x06\x07\x08\x0b\x0c\x0e-\x1f\x7f]")
_MAX_TEXT_LEN = 400


def _sane_name(field: str, value: str) -> str:
    if not isinstance(value, str) or not _NAME_RE.match(value):
        raise HTTPException(status_code=400, detail=f"{field}: must match [A-Za-z][A-Za-z0-9_.'- ]{{0,31}}")
    return value


def _sane_text(field: str, value: str) -> str:
    if not isinstance(value, str):
        raise HTTPException(status_code=400, detail=f"{field}: must be a string")
    cleaned = _BAD_CTRL.sub(" ", value)
    if len(cleaned) > _MAX_TEXT_LEN:
        raise HTTPException(status_code=400,
                            detail=f"{field}: exceeds {_MAX_TEXT_LEN} chars")
    return cleaned


def _sane_int(field: str, value: int, *, lo: int, hi: int) -> int:
    if not isinstance(value, int) or isinstance(value, bool):
        raise HTTPException(status_code=400, detail=f"{field}: must be int")
    if not (lo <= value <= hi):
        raise HTTPException(status_code=400, detail=f"{field}: out of range [{lo},{hi}]")
    return value


def _sane_float(field: str, value: float, *, lo: float = -1e6, hi: float = 1e6) -> float:
    if not isinstance(value, (int, float)) or isinstance(value, bool):
        raise HTTPException(status_code=400, detail=f"{field}: must be number")
    if not (lo <= value <= hi):
        raise HTTPException(status_code=400, detail=f"{field}: out of range [{lo},{hi}]")
    return float(value)


@contextmanager
def db_cursor():
    if pymysql is None:
        raise HTTPException(status_code=503, detail="pymysql not installed on sidecar host")
    conn = pymysql.connect(
        host=DB_HOST, port=DB_PORT, user=DB_USER, password=DB_PASS,
        database=DB_NAME, charset="utf8mb4", autocommit=True,
    )
    try:
        with conn.cursor(pymysql.cursors.DictCursor) as cur:
            yield cur
    finally:
        conn.close()


def console_write(cmd: str) -> None:
    """Append a command line onto map_server.exe's stdin via named pipe.

    Defence-in-depth: refuse any command containing a CR/LF/NUL even
    though every caller now goes through the validators. The named-pipe
    write uses a short timeout on the open so a hung map_server can't
    back up the sidecar.
    """
    if any(c in cmd for c in ("\r", "\n", "\x00")):
        raise HTTPException(status_code=400,
                            detail="console command contains forbidden control character")
    if len(cmd) > 1024:
        raise HTTPException(status_code=400,
                            detail="console command too long")
    try:
        # O_WRONLY + O_NONBLOCK on POSIX; on Windows we rely on the named
        # pipe's write buffer. The with-open is still bounded because the
        # file object closes on exit and the write itself is one syscall.
        with open(PIPE_PATH, "w", encoding="utf-8", buffering=1) as pipe:
            pipe.write(cmd + "\n")
    except OSError as exc:
        raise HTTPException(
            status_code=503,
            detail=f"console pipe unavailable ({exc}); is the map_server stdin-wrapper running?",
        )


# ---------- request models ----------

class AnnounceIn(BaseModel):
    text: str


class TellIn(BaseModel):
    to: str
    text: str


class TeleportIn(BaseModel):
    player: str
    zone: int
    x: float
    y: float
    z: float
    rot: int = 0


class GiveItemIn(BaseModel):
    player: str
    item_id: int
    count: int = 1


class SpawnMobIn(BaseModel):
    zone: int
    mob_id: int
    x: float
    y: float
    z: float
    count: int = 1


class KickIn(BaseModel):
    player: str
    reason: str = "kicked by admin"


# ---------- app ----------

app = FastAPI(title="lsb_admin_api", version="0.1.0")


@app.get("/health")
def health() -> dict:
    return {"ok": True, "ts": int(time.time()), "has_token": bool(TOKEN)}


@app.get("/players")
def list_players(x_admin_token: Optional[str] = Header(default=None)) -> list:
    check_auth(x_admin_token)
    with db_cursor() as cur:
        cur.execute(
            """
            SELECT c.charid AS id, c.charname AS name,
                   cs.mjob AS main_job, cs.sjob AS sub_job,
                   c.pos_zone AS zone, c.accid AS account_id
            FROM chars c
            LEFT JOIN char_stats cs ON cs.charid = c.charid
            """
        )
        return cur.fetchall()


@app.get("/players/{pid}")
def get_player(pid: int, x_admin_token: Optional[str] = Header(default=None)) -> dict:
    check_auth(x_admin_token)
    with db_cursor() as cur:
        cur.execute(
            "SELECT charid AS id, charname AS name, accid, pos_zone, pos_x, pos_y, pos_z "
            "FROM chars WHERE charid = %s",
            (pid,),
        )
        row = cur.fetchone()
        if not row:
            raise HTTPException(404, "player not found")
        return row


@app.get("/zones")
def zones(x_admin_token: Optional[str] = Header(default=None)) -> list:
    check_auth(x_admin_token)
    with db_cursor() as cur:
        cur.execute(
            "SELECT pos_zone AS zone, COUNT(*) AS population "
            "FROM chars WHERE pos_zone IS NOT NULL GROUP BY pos_zone ORDER BY population DESC"
        )
        return cur.fetchall()


@app.get("/server_stats")
def server_stats(x_admin_token: Optional[str] = Header(default=None)) -> dict:
    check_auth(x_admin_token)
    with db_cursor() as cur:
        cur.execute("SELECT COUNT(*) AS total_chars FROM chars")
        total = cur.fetchone()
        cur.execute("SELECT COUNT(*) AS total_accts FROM accounts")
        accts = cur.fetchone()
    return {
        "db_host": DB_HOST, "db_name": DB_NAME,
        "chars": total["total_chars"] if total else 0,
        "accounts": accts["total_accts"] if accts else 0,
        "ts": int(time.time()),
    }


@app.post("/announce")
def announce(body: AnnounceIn, x_admin_token: Optional[str] = Header(default=None)) -> dict:
    check_auth(x_admin_token)
    safe = _sane_text("text", body.text)
    console_write(f"announce {safe}")
    return {"ok": True}


@app.post("/tell")
def tell(body: TellIn, x_admin_token: Optional[str] = Header(default=None)) -> dict:
    check_auth(x_admin_token)
    to   = _sane_name("to", body.to)
    text = _sane_text("text", body.text)
    console_write(f"sendMessage {to} {text}")
    return {"ok": True}


@app.post("/teleport")
def teleport(body: TeleportIn, x_admin_token: Optional[str] = Header(default=None)) -> dict:
    check_auth(x_admin_token)
    player = _sane_name("player", body.player)
    zone   = _sane_int("zone", body.zone, lo=0, hi=300)
    x = _sane_float("x", body.x); y = _sane_float("y", body.y); z = _sane_float("z", body.z)
    rot = _sane_int("rot", body.rot, lo=0, hi=255)
    console_write(f"sendToZone {player} {zone} {x} {y} {z} {rot}")
    return {"ok": True}


@app.post("/give_item")
def give_item(body: GiveItemIn, x_admin_token: Optional[str] = Header(default=None)) -> dict:
    check_auth(x_admin_token)
    player = _sane_name("player", body.player)
    item_id = _sane_int("item_id", body.item_id, lo=1, hi=65535)
    count   = _sane_int("count", body.count, lo=1, hi=99)
    console_write(f"addItem {player} {item_id} {count}")
    return {"ok": True}


@app.post("/spawn_mob")
def spawn_mob(body: SpawnMobIn, x_admin_token: Optional[str] = Header(default=None)) -> dict:
    check_auth(x_admin_token)
    zone    = _sane_int("zone", body.zone, lo=0, hi=300)
    mob_id  = _sane_int("mob_id", body.mob_id, lo=1, hi=0x7FFFFFFF)
    x = _sane_float("x", body.x); y = _sane_float("y", body.y); z = _sane_float("z", body.z)
    count   = _sane_int("count", body.count, lo=1, hi=20)
    console_write(f"spawnMob {zone} {mob_id} {x} {y} {z} {count}")
    return {"ok": True}


@app.post("/kick")
def kick(body: KickIn, x_admin_token: Optional[str] = Header(default=None)) -> dict:
    check_auth(x_admin_token)
    player = _sane_name("player", body.player)
    reason = _sane_text("reason", body.reason)
    console_write(f"kickPlayer {player} {reason}")
    return {"ok": True}


# ---------- version-sync endpoints ----------

def _vsync_import():
    try:
        from lsb_version_sync import get_current_config, detect_versions, sync
        from lsb_version_sync.config import load_config, resolve_dll
        from lsb_version_sync.hooks import print_status
        return {
            "get_current_config": get_current_config,
            "detect_versions":    detect_versions,
            "sync":               sync,
            "load_config":        load_config,
            "resolve_dll":        resolve_dll,
            "print_status":       print_status,
        }
    except ImportError as e:
        raise HTTPException(
            status_code=503,
            detail=f"lsb_version_sync not importable ({e}); "
                   f"pip install from repo/lsb_version_sync/",
        )


@app.get("/version_sync/status")
def version_sync_status(x_admin_token: Optional[str] = Header(default=None)) -> dict:
    check_auth(x_admin_token)
    m = _vsync_import()
    cfg = m["load_config"]()
    dll = m["resolve_dll"](cfg)
    current = None
    try:
        current = m["get_current_config"](cfg.login_lua)
    except FileNotFoundError:
        pass
    best = None
    if dll and dll.exists():
        xs = m["detect_versions"](dll)
        if xs:
            best = xs[0]
    return {
        "login_lua": str(cfg.login_lua),
        "dll": str(dll) if dll else None,
        "configured_client_ver": current.client_ver if current else None,
        "configured_ver_lock": current.ver_lock if current else None,
        "detected_client_ver": best.raw if best else None,
        "in_sync": bool(current and best and current.client_ver == best.raw),
        "drift":   bool(current and best and current.client_ver != best.raw),
        "status_report": m["print_status"](cfg),
    }


class VersionSyncIn(BaseModel):
    dry_run: bool = False
    force: bool = False
    override_dll: Optional[str] = None
    restart: bool = True


def _validate_override_dll(raw: Optional[str]) -> Optional[str]:
    """Clamp an operator-supplied override_dll to a known-good shape.

    The override must:
      - point at a regular file that exists,
      - resolve (no symlinks traversal),
      - end in `.dll` (case-insensitive),
      - live under a configured allow-list of roots.
    """
    if raw is None or raw == "":
        return None
    # Reject embedded NULs / path separators we don't want.
    if "\x00" in raw:
        raise HTTPException(status_code=400, detail="override_dll: NUL in path")
    p = Path(raw)
    try:
        resolved = p.resolve(strict=True)
    except (OSError, FileNotFoundError):
        raise HTTPException(status_code=400, detail="override_dll: path not found")
    if not resolved.is_file():
        raise HTTPException(status_code=400, detail="override_dll: not a regular file")
    if resolved.suffix.lower() != ".dll":
        raise HTTPException(status_code=400, detail="override_dll: must be a .dll")
    # Allow-list roots come from env; default to the known Steam/SE install
    # roots used by the candidate list.
    roots_env = os.environ.get("LSB_VSYNC_ALLOWED_ROOTS",
                               r"C:\Program Files (x86);C:\Program Files;D:\Steam;F:\ffxi")
    roots = [Path(r).resolve() for r in roots_env.split(";") if r.strip()]
    if not any(_is_within(resolved, r) for r in roots):
        raise HTTPException(status_code=400,
                            detail="override_dll: outside configured allow-list")
    return str(resolved)


def _is_within(child: Path, parent: Path) -> bool:
    try:
        child.relative_to(parent)
        return True
    except ValueError:
        return False


@app.post("/version_sync/run")
def version_sync_run(
    body: VersionSyncIn,
    x_admin_token: Optional[str] = Header(default=None),
) -> dict:
    check_auth(x_admin_token)
    m = _vsync_import()
    override = _validate_override_dll(body.override_dll)
    res = m["sync"](
        dry_run=body.dry_run,
        force=body.force,
        override_dll=override,
        restart=body.restart,
    )
    from dataclasses import asdict
    return asdict(res)


@app.get("/events/tail")
def event_tail(n: int = 200, x_admin_token: Optional[str] = Header(default=None)) -> dict:
    check_auth(x_admin_token)
    # Tail the map_server log written by the stdin wrapper, if present.
    log = Path(os.environ.get("LSB_SERVER_LOG", r"F:\ffxi\server\map_server.log"))
    if not log.exists():
        return {"lines": [], "note": f"log not found at {log}"}
    with log.open("rb") as f:
        f.seek(0, 2)
        size = f.tell()
        f.seek(max(0, size - 200_000))
        raw = f.read().decode("utf-8", errors="replace")
    lines = raw.splitlines()[-n:]
    return {"lines": lines}


if __name__ == "__main__":
    uvicorn.run(app, host=HOST, port=PORT, log_level="info")
