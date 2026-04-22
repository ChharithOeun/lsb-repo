"""Command-line entry point: `python -m lsb_version_sync <subcommand>`.

Subcommands:
    status         - print current vs. detected versions; no writes
    detect         - scan the retail DLL, print all candidates
    sync           - detect -> patch -> restart (default)
    sync --dry-run - detect -> diff only
    scheduled      - the Task Scheduler entry point (same as `sync`)
"""
from __future__ import annotations

import argparse
import json
import sys
from dataclasses import asdict

from .config import load_config, resolve_dll
from .hooks import print_status, scheduled_run
from .scanner import detect_versions
from .sync import sync


def _cmd_status(args: argparse.Namespace) -> int:
    print(print_status())
    return 0


def _cmd_detect(args: argparse.Namespace) -> int:
    cfg = load_config()
    dll = args.dll or resolve_dll(cfg)
    if not dll:
        print("FFXiMain.dll not found; pass --dll explicitly", file=sys.stderr)
        return 1
    xs = detect_versions(dll)
    print(json.dumps({
        "dll": str(dll),
        "count": len(xs),
        "candidates": [asdict(c) for c in xs],
    }, indent=2, default=str))
    return 0 if xs else 2


def _cmd_sync(args: argparse.Namespace) -> int:
    result = sync(
        dry_run=args.dry_run,
        force=args.force,
        override_dll=args.dll,
        restart=not args.no_restart,
    )
    print(result.to_json())
    return 0 if result.ok else 1


def _cmd_scheduled(args: argparse.Namespace) -> int:
    result = scheduled_run()
    print(result.to_json())
    return 0 if result.ok else 1


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(prog="lsb_version_sync")
    sub = ap.add_subparsers(dest="cmd", required=True)

    sub.add_parser("status", help="print current vs detected versions")

    p_detect = sub.add_parser("detect", help="scan DLL and print candidates")
    p_detect.add_argument("--dll", help="path to FFXiMain.dll")

    p_sync = sub.add_parser("sync", help="detect, patch login.lua, bounce login_server")
    p_sync.add_argument("--dry-run", action="store_true")
    p_sync.add_argument("--force", action="store_true", help="override monotonicity guard")
    p_sync.add_argument("--dll", help="path to FFXiMain.dll (override)")
    p_sync.add_argument("--no-restart", action="store_true",
                        help="patch but don't bounce login_server")

    sub.add_parser("scheduled", help="Task Scheduler entry (same as `sync`)")

    ns = ap.parse_args(argv)
    handlers = {
        "status": _cmd_status,
        "detect": _cmd_detect,
        "sync": _cmd_sync,
        "scheduled": _cmd_scheduled,
    }
    return handlers[ns.cmd](ns)


if __name__ == "__main__":
    raise SystemExit(main())
