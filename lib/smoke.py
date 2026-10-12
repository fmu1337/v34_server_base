#!/usr/bin/env python3
"""Boot an installed CS:S v34 server once and check Metamod/SourceMod/plugins.

Talks to the server over Source RCON (TCP), so no expect/pty is needed.
Exit code 0 = everything loaded; the console log tail is printed on failure.

Usage: smoke.py SERVER_DIR [--sm none] [--expect-plugin NAME ...]
"""
from __future__ import annotations

import argparse
import os
import secrets
import socket
import struct
import subprocess
import sys
import time
from pathlib import Path

AUTH, EXEC = 3, 2


class Rcon:
    def __init__(self, host: str, port: int, password: str) -> None:
        self.sock = socket.create_connection((host, port), timeout=10)
        self.req = 0
        self._send(AUTH, password)
        # Source answers AUTH with an empty RESPONSE_VALUE and then AUTH_RESPONSE.
        for _ in range(2):
            rid, kind, _ = self._recv()
            if kind == 2:
                if rid == -1:
                    raise RuntimeError("rcon auth rejected")
                return
        raise RuntimeError("no rcon auth response")

    def _send(self, kind: int, body: str) -> int:
        self.req += 1
        data = struct.pack("<ii", self.req, kind) + body.encode() + b"\x00\x00"
        self.sock.sendall(struct.pack("<i", len(data)) + data)
        return self.req

    def _recvn(self, n: int) -> bytes:
        buf = b""
        while len(buf) < n:
            chunk = self.sock.recv(n - len(buf))
            if not chunk:
                raise RuntimeError("rcon connection closed")
            buf += chunk
        return buf

    def _recv(self) -> tuple[int, int, str]:
        (size,) = struct.unpack("<i", self._recvn(4))
        data = self._recvn(size)
        rid, kind = struct.unpack_from("<ii", data)
        return rid, kind, data[8:-2].decode("utf-8", "replace")

    def cmd(self, command: str) -> str:
        rid = self._send(EXEC, command)
        # Empty marker request: its reply ends a multi-packet answer.
        marker = self._send(0, "")
        out = []
        while True:
            got, _, body = self._recv()
            if got == marker:
                # srcds may send one more empty packet for the marker
                self.sock.settimeout(0.3)
                try:
                    self._recv()
                except (socket.timeout, RuntimeError):
                    pass
                self.sock.settimeout(10)
                return "".join(out)
            if got == rid:
                out.append(body)


def tail(path: Path, n: int = 60) -> str:
    try:
        return "\n".join(path.read_text(errors="replace").splitlines()[-n:])
    except OSError:
        return "(no file)"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("server_dir", type=Path)
    ap.add_argument("--sm", default="ours")
    ap.add_argument("--expect-plugin", action="append", default=[])
    ap.add_argument("--expect-ext", action="append", default=[])
    ap.add_argument("--port", type=int, default=27115)
    ap.add_argument("--boot-secs", type=int, default=120)
    ap.add_argument("--map", default="de_dust2")
    args = ap.parse_args()

    root = args.server_dir.resolve()
    windows = os.name == "nt"
    names = ("srcds.exe",) if windows else ("srcds_i686", "srcds_i486")
    binary = next((b for b in names if (root / b).is_file()), None)
    if not binary:
        print(f"FAIL: no {'/'.join(names)} in {root}", file=sys.stderr)
        return 1
    console = root / "cstrike" / "console.log"
    console.unlink(missing_ok=True)

    password = secrets.token_hex(8)
    env = dict(os.environ, LD_LIBRARY_PATH=f".:bin:{os.environ.get('LD_LIBRARY_PATH', '')}")
    if windows:
        # Same argument set as the native Windows smoke in sourcemod-css34;
        # -nomaster/-localcser keep srcds.exe stuck right after "Network:".
        cmd = [str(root / binary), "-console", "-condebug", "-game", "cstrike",
               "-insecure", "-nohltv", "-ip", "127.0.0.1", "-port", str(args.port),
               "+sv_lan", "1", "+maxplayers", "10", "+rcon_password", password, "+ip", "127.0.0.1",
               "+map", args.map]
    else:
        cmd = [
            f"./{binary}", "-game", "cstrike", "-console", "-condebug", "-nohltv",
            "-nomaster", "-localcser", "-insecure", "-tickrate", "66",
            "-ip", "127.0.0.1", "-port", str(args.port),
            "+sv_lan", "1", "+maxplayers", "10", "+rcon_password", password,
            "+map", args.map,
        ]
    print("boot:", " ".join(c if c != password else "***" for c in cmd))
    if windows:
        # srcds.exe needs a real console: with a pipe on stdin it spins on
        # "CTextConsoleWin32::GetLine" and never loads the map.
        proc = subprocess.Popen(cmd, cwd=root, env=env,
                                creationflags=subprocess.CREATE_NEW_CONSOLE)
    else:
        proc = subprocess.Popen(
            cmd, cwd=root, env=env, stdin=subprocess.PIPE,
            stdout=subprocess.DEVNULL, stderr=subprocess.STDOUT,
        )

    failures: list[str] = []
    rcon = None
    deadline = time.time() + args.boot_secs
    while time.time() < deadline:
        if proc.poll() is not None:
            failures.append(f"srcds exited early with code {proc.returncode}")
            break
        try:
            rcon = Rcon("127.0.0.1", args.port, password)
            break
        except (OSError, RuntimeError):
            time.sleep(2)
    else:
        failures.append(f"no rcon after {args.boot_secs}s")

    if rcon:
        time.sleep(5)  # let plugins finish OnPluginStart / OnMapStart
        status = rcon.cmd("status")
        print(status)
        if args.map not in status:
            failures.append(f"map {args.map} not running")
        if args.sm != "none":
            for c in ("meta version", "sm version", "sm exts list", "sm plugins list"):
                out = rcon.cmd(c)
                print(f"] {c}\n{out}")
                if c == "meta version" and "Metamod:Source" not in out:
                    failures.append("Metamod not loaded")
                if c == "sm version" and "SourceMod" not in out:
                    failures.append("SourceMod not loaded")
                if c == "sm exts list":
                    if "<FAILED>" in out:
                        failures.append("an extension failed to load")
                    for name in args.expect_ext:
                        if name.lower() not in out.lower():
                            failures.append(f"extension {name} not loaded")
                if c == "sm plugins list":
                    for line in out.splitlines():
                        if "<Failed>" in line or "<Error>" in line:
                            failures.append(f"plugin failed: {line.strip()}")
                    for name in args.expect_plugin:
                        # `sm plugins list` shows titles ("SMAC: Core"), not file names
                        if name.lower().replace(" ", "") not in out.lower().replace(" ", ""):
                            failures.append(f"plugin {name} not listed")
        try:
            rcon.cmd("quit")
        except Exception:
            pass

    try:
        proc.wait(timeout=15)
    except subprocess.TimeoutExpired:
        proc.kill()
        proc.wait()

    log = console.read_text(errors="replace") if console.is_file() else ""
    if log.count("Unknown command") > 50:
        failures.append("console flooded with 'Unknown command' (buffer bug; use --patch bufferfix)")
    if "Segmentation fault" in log:
        failures.append("segfault")

    if failures:
        if windows:
            subprocess.run(["netstat", "-ano", "-p", "TCP"], check=False)
            subprocess.run(["tasklist", "/FI", "IMAGENAME eq srcds.exe"], check=False)
        print("==== console.log (tail) ====")
        print(tail(console))
        for f in failures:
            print(f"FAIL: {f}", file=sys.stderr)
        return 1
    print("SMOKE OK")
    return 0


if __name__ == "__main__":
    sys.exit(main())
