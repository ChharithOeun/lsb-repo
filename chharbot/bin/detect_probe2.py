"""detect_probe2.py - walk all plausible FFXi install paths, find every
FFXiMain.dll / polcore*.dll / ffxi*.dll / xiloader*.dll, and dump:
  - size
  - sha256 (first 16 hex)
  - count of strict YYYYMMDD_R matches (ASCII + UTF-16LE)
  - count of ANY 8-digit sequence
  - nearby printable context for any 8-digit match
  - occurrences of 'CLIENT' / 'VER' / 'LOCK' strings (both encodings)

Writes chharbot\\bin\\detect_probe2.log.
"""
from __future__ import annotations

import hashlib
import re
import sys
import traceback
from pathlib import Path

LOG = Path(__file__).with_name("detect_probe2.log")


def log(msg: str) -> None:
    print(msg)
    with LOG.open("a", encoding="utf-8") as f:
        f.write(msg + "\n")


DLL_NAMES = (
    "FFXiMain.dll",
    "FFXimain.dll",
    "polcore.dll",
    "polcoreE.dll",
    "xiloader.dll",
    "xiloader.exe",
    "pol.exe",
    "PlayOnline.exe",
)

# Roots to walk (only if they exist)
SEARCH_ROOTS = [
    r"C:\Program Files (x86)\Steam\steamapps\common\FFXINA",
    r"C:\Program Files (x86)\SquareEnix",
    r"C:\Program Files\SquareEnix",
    r"C:\Program Files (x86)\PlayOnline",
    r"C:\Program Files\PlayOnline",
    r"D:\Steam\steamapps\common\FFXINA",
    r"F:\ffxi\ashita",
    r"F:\ffxi\windower",
    r"F:\ffxi",
]


STRICT_ASCII = re.compile(rb"(?<![0-9_])([0-9]{8})_([0-9]{1,2})(?![0-9_])")
STRICT_U16 = re.compile(
    rb"(?<![0-9_])" +
    rb"".join(b"([0-9])\x00" for _ in range(8)) +
    rb"_\x00" +
    rb"([0-9])\x00(?:([0-9])\x00)?" +
    rb"(?![0-9_])"
)
BROAD_ASCII = re.compile(rb"([0-9]{8})")
BROAD_ASCII_UNDERSCORE = re.compile(rb"([0-9]{8})_([0-9]{1,2})")
CLIENT_ASCII = re.compile(rb"CLIENT[_A-Za-z]{0,10}", re.IGNORECASE)
# 'CLIENT' in UTF-16LE: C\0L\0I\0E\0N\0T\0
CLIENT_U16 = re.compile(rb"(?:[A-Za-z]\x00){6,20}")  # any run of 6+ ASCII wide chars - too broad
CLIENT_U16_SPECIFIC = re.compile(
    rb"C\x00L\x00I\x00E\x00N\x00T\x00", re.IGNORECASE)
VER_U16 = re.compile(rb"V\x00E\x00R\x00", re.IGNORECASE)


def sample_ctx(data: bytes, start: int, end: int, pad: int = 16) -> str:
    s = max(0, start - pad)
    e = min(len(data), end + pad)
    chunk = data[s:e]
    return "".join(chr(b) if 32 <= b < 127 else "." for b in chunk)


def scan_one(path: Path) -> None:
    log(f"--- {path} ---")
    try:
        size = path.stat().st_size
        log(f"    size   : {size:,} bytes")
    except OSError as e:
        log(f"    stat FAIL: {e}")
        return

    try:
        data = path.read_bytes()
    except OSError as e:
        log(f"    read FAIL: {e}")
        return

    h = hashlib.sha256(data).hexdigest()
    log(f"    sha256 : {h[:32]}...")

    # Strict official pattern
    sa = list(STRICT_ASCII.finditer(data))
    su = list(STRICT_U16.finditer(data))
    log(f"    strict ASCII YYYYMMDD_R : {len(sa)} hit(s)")
    for m in sa[:10]:
        ctx = sample_ctx(data, m.start(), m.end())
        log(f"        off=0x{m.start():08x}  {m.group(0).decode('ascii', 'replace')!r}  ctx={ctx!r}")
    log(f"    strict UTF-16 YYYYMMDD_R: {len(su)} hit(s)")
    for m in su[:10]:
        ctx = sample_ctx(data, m.start(), m.end(), pad=24)
        log(f"        off=0x{m.start():08x}  ctx={ctx!r}")

    # Broad: any 8-digit run (ASCII)
    b8 = list(BROAD_ASCII.finditer(data))
    log(f"    broad  8-digit ASCII    : {len(b8)} hit(s)")
    seen = set()
    shown = 0
    for m in b8:
        s = m.group(0).decode("ascii", "replace")
        if s in seen:
            continue
        seen.add(s)
        ctx = sample_ctx(data, m.start(), m.end())
        log(f"        {s}  off=0x{m.start():08x}  ctx={ctx!r}")
        shown += 1
        if shown >= 25:
            log(f"        ... (truncated; {len(seen)} unique before trunc)")
            break

    # Broad: 8-digit underscore 1-2 digit (no guard)
    bu = list(BROAD_ASCII_UNDERSCORE.finditer(data))
    log(f"    broad  8dig_Ndig  ASCII : {len(bu)} hit(s)")
    for m in bu[:10]:
        ctx = sample_ctx(data, m.start(), m.end())
        log(f"        off=0x{m.start():08x}  {m.group(0).decode('ascii', 'replace')!r}  ctx={ctx!r}")

    # CLIENT* strings
    ca = list(CLIENT_ASCII.finditer(data))
    log(f"    'CLIENT*' ASCII         : {len(ca)} hit(s)")
    for m in ca[:5]:
        ctx = sample_ctx(data, m.start(), m.end(), pad=24)
        log(f"        off=0x{m.start():08x}  ctx={ctx!r}")
    cu = list(CLIENT_U16_SPECIFIC.finditer(data))
    log(f"    'CLIENT' UTF-16LE       : {len(cu)} hit(s)")
    for m in cu[:5]:
        ctx = sample_ctx(data, m.start(), m.end(), pad=32)
        log(f"        off=0x{m.start():08x}  ctx={ctx!r}")

    vu = list(VER_U16.finditer(data))
    log(f"    'VER' UTF-16LE (substr) : {len(vu)} hit(s) (first 3 only)")
    for m in vu[:3]:
        ctx = sample_ctx(data, m.start(), m.end(), pad=24)
        log(f"        off=0x{m.start():08x}  ctx={ctx!r}")


def main() -> int:
    if LOG.exists():
        LOG.unlink()

    log("=== detect_probe2 - wide DLL walk ===")
    log(f"python: {sys.version}")

    found: list[Path] = []
    for root in SEARCH_ROOTS:
        rp = Path(root)
        if not rp.exists():
            log(f"(skip) root missing: {root}")
            continue
        log(f"walking: {rp}")
        try:
            for sub in rp.rglob("*"):
                try:
                    if not sub.is_file():
                        continue
                    if sub.name in DLL_NAMES:
                        found.append(sub)
                except OSError:
                    continue
        except Exception:
            traceback.print_exc(file=sys.stdout)
            with LOG.open("a", encoding="utf-8") as f:
                traceback.print_exc(file=f)

    # Dedup by resolved path
    seen: set[str] = set()
    uniq: list[Path] = []
    for p in found:
        try:
            rp = str(p.resolve())
        except OSError:
            rp = str(p)
        if rp in seen:
            continue
        seen.add(rp)
        uniq.append(p)

    log(f"\n=== found {len(uniq)} candidate binaries ===")
    for p in uniq:
        log(f"  {p}")
    log("")

    for p in uniq:
        try:
            scan_one(p)
        except Exception:
            log(f"scan fail on {p}")
            traceback.print_exc(file=sys.stdout)
            with LOG.open("a", encoding="utf-8") as f:
                traceback.print_exc(file=f)

    log("=== done ===")
    return 0


if __name__ == "__main__":
    sys.exit(main())
