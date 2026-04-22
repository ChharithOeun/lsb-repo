"""map_server_stdin_pump.py - one-line wrapper that spawns map_server.exe
with its stdin wired to a Windows named pipe, so lsb_admin_api can inject
GM console commands by opening the pipe and writing a line.

Run this instead of launching map_server.exe directly. Kill it to stop
the server.

Usage:
    python map_server_stdin_pump.py F:\\ffxi\\server\\map_server.exe

It will:
    1. Create a named pipe at \\.\\pipe\\lsb_admin (configurable).
    2. Start map_server.exe with stdin=<read end of pipe>.
    3. Tail map_server's stdout+stderr to both the console and
       F:\\ffxi\\server\\map_server.log.
    4. Block until map_server exits; then close everything.

Requires Python 3.9+ on Windows (uses built-in subprocess + ctypes for
pipes). No third-party dependencies.
"""
from __future__ import annotations

import os
import subprocess
import sys
import threading
import time
from pathlib import Path

PIPE_NAME = os.environ.get("LSB_ADMIN_PIPE", r"\\.\pipe\lsb_admin")
LOG_PATH = Path(os.environ.get("LSB_SERVER_LOG", r"F:\ffxi\server\map_server.log"))


def _win_pipes():
    """Create an anonymous pipe for stdin and a named pipe for writes."""
    import ctypes
    import ctypes.wintypes as wt
    import msvcrt

    PIPE_ACCESS_OUTBOUND = 0x00000002
    PIPE_TYPE_BYTE = 0x00000000
    PIPE_WAIT = 0x00000000
    kernel32 = ctypes.windll.kernel32

    # Named pipe server handle. Writers (lsb_admin_api) connect as clients.
    h_named = kernel32.CreateNamedPipeW(
        PIPE_NAME,
        PIPE_ACCESS_OUTBOUND,
        PIPE_TYPE_BYTE | PIPE_WAIT,
        1, 65536, 65536, 0, None,
    )
    if h_named == -1:
        raise OSError(f"CreateNamedPipe failed: {ctypes.get_last_error()}")

    # Anonymous pipe pair used as child's stdin.
    read_fd, write_fd = os.pipe()
    # Make write end inheritable? Actually child reads from read_fd.
    os.set_inheritable(read_fd, True)
    return h_named, read_fd, write_fd


def pump_named_to_child(h_named, write_fd, stop):
    import ctypes
    import ctypes.wintypes as wt
    kernel32 = ctypes.windll.kernel32
    while not stop.is_set():
        # Block until a writer connects, then forward bytes to child stdin.
        ok = kernel32.ConnectNamedPipe(h_named, None)
        if not ok:
            time.sleep(0.1)
            continue
        try:
            buf = ctypes.create_string_buffer(4096)
            read = wt.DWORD(0)
            while not stop.is_set():
                if not kernel32.ReadFile(h_named, buf, 4096, ctypes.byref(read), None):
                    break
                if read.value == 0:
                    break
                os.write(write_fd, buf.raw[:read.value])
        finally:
            kernel32.DisconnectNamedPipe(h_named)


def tee_reader(src, dst_file):
    for line in iter(src.readline, b""):
        sys.stdout.buffer.write(line)
        sys.stdout.flush()
        dst_file.write(line)
        dst_file.flush()


def main():
    if len(sys.argv) < 2:
        print("usage: map_server_stdin_pump.py <path-to-map_server.exe>")
        sys.exit(1)
    exe = Path(sys.argv[1])
    if not exe.exists():
        print(f"map_server.exe not found: {exe}"); sys.exit(1)

    LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
    h_named, read_fd, write_fd = _win_pipes()

    stop = threading.Event()
    t = threading.Thread(target=pump_named_to_child, args=(h_named, write_fd, stop), daemon=True)
    t.start()

    proc = subprocess.Popen(
        [str(exe)],
        cwd=exe.parent,
        stdin=read_fd,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        close_fds=False,
    )
    os.close(read_fd)  # child has it

    with LOG_PATH.open("ab") as logf:
        tee = threading.Thread(target=tee_reader, args=(proc.stdout, logf), daemon=True)
        tee.start()
        try:
            proc.wait()
        finally:
            stop.set()


if __name__ == "__main__":
    main()
