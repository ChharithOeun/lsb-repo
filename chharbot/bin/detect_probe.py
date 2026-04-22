"""detect_probe.py - poke the version scanner directly.

Runs lsb_version_sync.scanner.detect_versions against whatever
FFXiMain.dll resolve_dll() picks, prints the candidate list, and then
does a raw byte scan with looser patterns so we can see what the DLL
actually contains near any 8-digit date string.

Writes a log next to itself.
"""
from __future__ import annotations

import re
import sys
import traceback
from pathlib import Path

LOG = Path(__file__).with_name("detect_probe.log")


def log(msg: str) -> None:
    print(msg)
    with LOG.open("a", encoding="utf-8") as f:
        f.write(msg + "\n")


def main() -> int:
    if LOG.exists():
        LOG.unlink()

    log("=== lsb_version_sync detect probe ===")
    log(f"python: {sys.version}")

    try:
        from lsb_version_sync.config import load_config, resolve_dll
        from lsb_version_sync.scanner import detect_versions, _ASCII_PAT, _UTF16_PAT, _normalize
    except Exception:
        log("import lsb_version_sync: FAIL")
        traceback.print_exc(file=sys.stdout)
        with LOG.open("a", encoding="utf-8") as f:
            traceback.print_exc(file=f)
        return 1

    cfg = load_config()
    log(f"login_lua       : {cfg.login_lua}")
    log(f"dll_candidates  : {getattr(cfg, 'dll_candidates', None)}")

    dll = resolve_dll(cfg)
    log(f"resolved dll    : {dll}")
    if not dll or not Path(dll).exists():
        log("ERROR: dll not resolved or missing")
        return 2
    dll = Path(dll)
    size = dll.stat().st_size
    log(f"dll size        : {size:,} bytes")

    # 1) Official scanner
    try:
        cands = detect_versions(dll)
        log(f"official scan   : {len(cands)} candidate(s)")
        for c in cands[:10]:
            log(f"    {c.raw!r}  off=0x{c.offset:08x}  enc={c.encoding}")
    except Exception:
        log("official scan FAIL")
        traceback.print_exc(file=sys.stdout)
        with LOG.open("a", encoding="utf-8") as f:
            traceback.print_exc(file=f)

    # 2) Raw broad scan: any 8 digits underscore 1-2 digits, even without
    #    the surrounding non-digit guards.
    try:
        raw = dll.read_bytes()
        broad = re.compile(rb"([0-9]{8})_([0-9]{1,2})")
        matches = list(broad.finditer(raw))
        log(f"broad ASCII     : {len(matches)} hit(s) (no guard)")
        seen = set()
        kept = 0
        for m in matches:
            date = m.group(1).decode("ascii", "replace")
            rev = m.group(2).decode("ascii", "replace")
            key = (date, rev)
            if key in seen:
                continue
            seen.add(key)
            kept += 1
            ctx_start = max(0, m.start() - 12)
            ctx_end = min(len(raw), m.end() + 12)
            ctx = raw[ctx_start:ctx_end]
            printable = "".join(chr(b) if 32 <= b < 127 else "." for b in ctx)
            log(f"    {date}_{rev}  off=0x{m.start():08x}  ctx={printable!r}")
            if kept >= 30:
                log("    ... (truncated at 30 unique dates)")
                break

        # 3) Same but UTF-16LE: 8 digit chars each followed by \x00.
        utf16 = re.compile(
            rb"".join(b"([0-9])\x00" for _ in range(8)) +
            rb"_\x00([0-9])\x00(?:([0-9])\x00)?"
        )
        u16 = list(utf16.finditer(raw))
        log(f"broad UTF-16LE  : {len(u16)} hit(s) (no guard)")
        seen.clear()
        kept = 0
        for m in u16:
            date = "".join(m.group(i).decode("ascii") for i in range(1, 9))
            rev = m.group(9).decode("ascii")
            if m.group(10):
                rev += m.group(10).decode("ascii")
            key = (date, rev)
            if key in seen:
                continue
            seen.add(key)
            kept += 1
            ctx_start = max(0, m.start() - 16)
            ctx_end = min(len(raw), m.end() + 16)
            ctx = raw[ctx_start:ctx_end]
            printable = "".join(chr(b) if 32 <= b < 127 else "." for b in ctx)
            log(f"    {date}_{rev}  off=0x{m.start():08x}  ctx={printable!r}")
            if kept >= 30:
                log("    ... (truncated at 30 unique dates)")
                break

        # 4) Run _normalize on the broad hits so we see which fail and why.
        rejected = 0
        for m in matches:
            date = m.group(1).decode("ascii", "replace")
            rev = int(m.group(2).decode("ascii", "replace"))
            n = _normalize(date, rev)
            if n is None:
                rejected += 1
        log(f"normalize reject: {rejected}/{len(matches)} broad ASCII hits rejected")
    except Exception:
        log("broad scan FAIL")
        traceback.print_exc(file=sys.stdout)
        with LOG.open("a", encoding="utf-8") as f:
            traceback.print_exc(file=f)
        return 3

    log("=== done ===")
    return 0


if __name__ == "__main__":
    sys.exit(main())
