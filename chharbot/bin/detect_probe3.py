"""detect_probe3.py - hunt for CLIENT_VER in config/data files (not DLLs).

Modern retail FFXI DLLs don't embed YYYYMMDD_R strings anywhere the
scanner can find. The CLIENT_VER that xiloader sends to the login
server probably lives in a CONFIG file: xiloader.ini, Ashita's boot.cfg,
or a data pack next to the client.

This probe walks the FFXI install trees looking for small text-ish files
(.ini, .cfg, .toml, .xml, .txt, .json, .yaml, .bat, .ps1, .lua) and dumps
any line containing 'client', 'ver', 'lock', or an 8-digit date pattern.
Also looks for a `ver` file (no extension) in POLViewer.
"""
from __future__ import annotations

import re
import sys
import traceback
from pathlib import Path

LOG = Path(__file__).with_name("detect_probe3.log")
TEXT_EXT = {
    ".ini", ".cfg", ".conf", ".toml", ".yaml", ".yml",
    ".xml", ".txt", ".json", ".bat", ".ps1", ".lua",
    ".log", ".md", ".inf", ".dat",
}
NAMES_OF_INTEREST = {
    "ver", "version", "ver.dat", "boot.cfg", "xiloader.ini",
    "xiloader.cfg", "client.ver", "login.cfg", "pol.cfg",
}
ROOTS = [
    r"C:\Program Files (x86)\Steam\steamapps\common\FFXINA",
    r"F:\ffxi\ashita",
    r"F:\ffxi\windower",
    r"F:\ffxi\client",
    r"F:\ffxi\server\settings",
    r"F:\ffxi\deploy",
]
MAX_FILE_BYTES = 256 * 1024  # 256 KB
NEEDLE_PAT = re.compile(
    rb"(?i)(client_ver|ver_lock|CLIENT_VER|VER_LOCK|client\s*=|version\s*[:=]|[0-9]{8}_[0-9]{1,2})"
)


def log(msg: str) -> None:
    print(msg)
    with LOG.open("a", encoding="utf-8") as f:
        f.write(msg + "\n")


def scan_file(p: Path) -> int:
    """Return number of interesting lines printed."""
    try:
        size = p.stat().st_size
    except OSError:
        return 0
    if size > MAX_FILE_BYTES:
        return 0
    try:
        data = p.read_bytes()
    except OSError:
        return 0

    hits = list(NEEDLE_PAT.finditer(data))
    if not hits:
        return 0
    log(f"--- {p}  ({size:,} bytes) ---")
    seen_lines = set()
    printed = 0
    for m in hits:
        # Find the line containing this match
        line_start = data.rfind(b"\n", 0, m.start()) + 1
        line_end = data.find(b"\n", m.end())
        if line_end == -1:
            line_end = len(data)
        line = data[line_start:line_end]
        # Decode printable
        try:
            s = line.decode("utf-8", errors="replace").strip()
        except Exception:
            s = line.decode("latin-1", errors="replace").strip()
        if s in seen_lines:
            continue
        seen_lines.add(s)
        if len(s) > 200:
            s = s[:200] + "..."
        log(f"    {s}")
        printed += 1
        if printed >= 30:
            log("    ... (truncated at 30 lines)")
            break
    return printed


def main() -> int:
    if LOG.exists():
        LOG.unlink()

    log("=== detect_probe3 - config/text file scan ===")
    log(f"python: {sys.version}")

    scanned = 0
    hit_files = 0

    for root in ROOTS:
        rp = Path(root)
        if not rp.exists():
            log(f"(skip) root missing: {rp}")
            continue
        log(f"\nwalking: {rp}")
        try:
            for sub in rp.rglob("*"):
                try:
                    if not sub.is_file():
                        continue
                    name = sub.name.lower()
                    ext = sub.suffix.lower()
                    if ext in TEXT_EXT or name in NAMES_OF_INTEREST:
                        scanned += 1
                        if scan_file(sub) > 0:
                            hit_files += 1
                except OSError:
                    continue
        except Exception:
            traceback.print_exc(file=sys.stdout)
            with LOG.open("a", encoding="utf-8") as f:
                traceback.print_exc(file=f)

    log(f"\n=== done: {scanned} files scanned, {hit_files} had hits ===")
    return 0


if __name__ == "__main__":
    sys.exit(main())
