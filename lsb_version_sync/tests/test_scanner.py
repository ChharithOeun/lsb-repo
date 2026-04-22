"""Tests for scanner.py - candidate version extraction from raw bytes."""
from __future__ import annotations

from lsb_version_sync.scanner import (
    CandidateVersion,
    best_version,
    detect_versions,
)


def test_finds_single_ascii_version():
    blob = b"\x00stuff\x00  30260203_0  more\x00"
    xs = detect_versions(blob)
    assert len(xs) == 1
    assert xs[0].raw == "30260203_0"
    assert xs[0].encoding == "ascii"


def test_picks_newest_when_multiple():
    blob = b"a 30240101_0 b 30260405_2 c 30250707_0 d"
    xs = detect_versions(blob)
    assert [c.raw for c in xs] == ["30260405_2", "30250707_0", "30240101_0"]


def test_ignores_non_plausible_dates():
    # 19991301 = bad month/year, 50000000_0 = decade not in _ACCEPTABLE_LEAD
    blob = b" 19991301_0  50000000_0  30260203_0 "
    xs = detect_versions(blob)
    assert [c.raw for c in xs] == ["30260203_0"]


def test_utf16le_match():
    import codecs
    payload = codecs.encode("retail ver 30260715_1 here", "utf-16-le")
    xs = detect_versions(payload)
    assert any(c.raw == "30260715_1" and c.encoding == "utf16le" for c in xs)


def test_best_version_returns_newest():
    blob = b" 30240101_0 30260203_0 30250707_0 "
    b = best_version(blob)
    assert b is not None and b.raw == "30260203_0"


def test_no_matches_returns_empty():
    assert detect_versions(b"no dates here at all") == []


def test_accepts_two_digit_revision():
    blob = b" 30260203_12 "
    xs = detect_versions(blob)
    assert xs and xs[0].raw == "30260203_12"
    assert xs[0].revision == 12


def test_unique_dedupes_repeats():
    blob = b" 30260203_0  padding 30260203_0  more "
    xs = detect_versions(blob, unique=True)
    assert [c.raw for c in xs] == ["30260203_0"]


def test_plain_20yy_year_also_accepted():
    blob = b" 20260203_0 "
    xs = detect_versions(blob)
    assert xs and xs[0].raw == "20260203_0"
