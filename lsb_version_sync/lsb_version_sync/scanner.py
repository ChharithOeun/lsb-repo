"""scanner.py - extract candidate CLIENT_VER strings from the retail
FFXiMain.dll binary.

FFXI's version handshake sends a date-stamped string to the login server.
On retail clients the string lives embedded in FFXiMain.dll (and a couple
of sibling DLLs). It appears as either ASCII or UTF-16LE bytes and takes
the form:

    YYYYMMDD_R          canonical public format
    30YYMMDD_R          SE's internal encoding (leading "30" for 2000s+)

with R typically 0-9. We don't trust a single match - the DLL also
contains date-like strings from debug builds, QA stamps, and resource
tables - so we collect every candidate and pick the lexicographically
largest one from a narrow allow-list. That matches LSB's own comparator
so the sync produces a string LSB's `VER_LOCK = 2` (greater-or-equal)
path will accept.

The scanner is deliberately tolerant: it works on FFXiMain.dll, the
bootloader binary (if you're auto-matching xiloader instead), or any
chunk of bytes you point it at. No imports beyond the standard library.
"""
from __future__ import annotations

import mmap
import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable, List, Optional


# ASCII pattern: look for an 8-digit date-stamp followed by `_` and 1-2
# digits, bracketed by non-digit characters so we don't chop mid-number.
_ASCII_PAT = re.compile(rb"(?<![0-9_])([0-9]{8})_([0-9]{1,2})(?![0-9_])")

# UTF-16LE pattern: same shape but every byte is followed by a null, so
# the regex works on the raw bytes.
_UTF16_PAT = re.compile(
    rb"(?<![0-9_])" +
    rb"".join(b"([0-9])\x00" for _ in range(8)) +
    rb"_\x00" +
    rb"([0-9])\x00(?:([0-9])\x00)?" +
    rb"(?![0-9_])"
)


# Accept any date whose leading decade is plausible for FFXI's lifetime.
# FFXI launched 2002; we'll accept 2000-2039 inclusive (the "30YY" encoding
# covers 2000-2099 nominally but nothing past 2039 is meaningful yet).
_ACCEPTABLE_LEAD = ("20", "30")


@dataclass(order=True, frozen=True)
class CandidateVersion:
    """A candidate CLIENT_VER string found in the binary.

    Comparisons use `(date, revision)` so sorting picks the newest.
    """
    date: str          # '30260203' or '20260203'
    revision: int      # 0, 1, 2...
    raw: str = field(compare=False)           # 'YYYYMMDD_R'
    offset: int = field(default=0, compare=False)
    encoding: str = field(default="ascii", compare=False)

    def __str__(self) -> str:
        return self.raw


def _normalize(date: str, rev: int) -> Optional[CandidateVersion]:
    """Return a CandidateVersion if `date` looks like a plausible FFXI stamp."""
    if len(date) != 8 or not date.isdigit():
        return None
    if date[:2] not in _ACCEPTABLE_LEAD:
        return None
    yyyy = int(date[:4])
    mm = int(date[4:6])
    dd = int(date[6:8])
    # "30YY" encoded year => real year is 2000 + (YYYY - 3000) = YYYY - 1000
    if date[:2] == "30":
        real_year = yyyy - 1000
    else:
        real_year = yyyy
    if not (2002 <= real_year <= 2039):
        return None
    if not (1 <= mm <= 12 and 1 <= dd <= 31):
        return None
    return CandidateVersion(
        date=date, revision=rev,
        raw=f"{date}_{rev}",
    )


def _scan_bytes(data: bytes) -> Iterable[CandidateVersion]:
    for m in _ASCII_PAT.finditer(data):
        cand = _normalize(m.group(1).decode("ascii"), int(m.group(2)))
        if cand:
            yield CandidateVersion(
                date=cand.date, revision=cand.revision,
                raw=cand.raw, offset=m.start(), encoding="ascii",
            )
    for m in _UTF16_PAT.finditer(data):
        # groups 1..8 = date digits, 9 = first rev digit, 10 = optional 2nd
        date = "".join(m.group(i).decode("ascii") for i in range(1, 9))
        rev_str = m.group(9).decode("ascii")
        if m.group(10):
            rev_str += m.group(10).decode("ascii")
        cand = _normalize(date, int(rev_str))
        if cand:
            yield CandidateVersion(
                date=cand.date, revision=cand.revision,
                raw=cand.raw, offset=m.start(), encoding="utf16le",
            )


def detect_versions(
    target: str | Path,
    *,
    unique: bool = True,
) -> List[CandidateVersion]:
    """Scan `target` and return candidate version strings, newest first.

    `target` may be a file path (mmap'd) or raw bytes (for tests).
    """
    if isinstance(target, (bytes, bytearray, memoryview)):
        data = bytes(target)
        cands = list(_scan_bytes(data))
    else:
        p = Path(target)
        if not p.exists():
            raise FileNotFoundError(f"not found: {p}")
        with p.open("rb") as f:
            with mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_READ) as mm:
                cands = list(_scan_bytes(mm))

    if unique:
        seen = set()
        dedup: List[CandidateVersion] = []
        for c in cands:
            if c.raw in seen:
                continue
            seen.add(c.raw)
            dedup.append(c)
        cands = dedup

    # Newest first: (date desc, revision desc).
    cands.sort(key=lambda c: (c.date, c.revision), reverse=True)
    return cands


def best_version(target: str | Path) -> Optional[CandidateVersion]:
    """Return the single best (newest) candidate, or None if nothing matched."""
    xs = detect_versions(target)
    return xs[0] if xs else None
