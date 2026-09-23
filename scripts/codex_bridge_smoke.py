#!/usr/bin/env python3
"""Verify the packaged bridge starts and reports logged out without credentials."""

import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: codex_bridge_smoke.py <bundled-helper>")
    helper = Path(sys.argv[1]).resolve(strict=True)
    with tempfile.TemporaryDirectory(prefix="loom-codex-smoke-") as home:
        command = json.dumps({"v": 1, "id": "smoke", "cmd": "status", "profile": "smoke"}).encode()
        frame = struct.pack(">I", len(command)) + command
        result = subprocess.run(
            [str(helper), "--profile", "smoke"],
            input=frame,
            capture_output=True,
            cwd="/",
            env={"HOME": home, "XDG_CONFIG_HOME": home, "PATH": "/usr/bin:/bin"},
            timeout=5,
            check=True,
        )
        if result.stderr:
            raise AssertionError("bridge wrote unexpected diagnostics")
        frames = []
        offset = 0
        while offset < len(result.stdout):
            if len(result.stdout) - offset < 4:
                raise AssertionError("bridge returned a partial frame length")
            length = struct.unpack(">I", result.stdout[offset : offset + 4])[0]
            offset += 4
            if length == 0 or length > 4 << 20 or offset + length > len(result.stdout):
                raise AssertionError("bridge returned an invalid frame length")
            frames.append(json.loads(result.stdout[offset : offset + length]))
            offset += length
        if len(frames) != 2:
            raise AssertionError("bridge omitted status or drain frame")
        status, drained = frames
        if status != {"v": 1, "id": "smoke", "event": "status", "code": "logged_out"}:
            raise AssertionError("bridge did not report logged-out status")
        if drained != {"v": 1, "id": "smoke", "event": "end"}:
            raise AssertionError("bridge omitted status drain confirmation")
        if list(Path(home).rglob("*.json")):
            raise AssertionError("bridge created credentials during logged-out status")
    print("codex-bridge: bundled helper reports logged out without credentials")


if __name__ == "__main__":
    main()
