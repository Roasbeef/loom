#!/usr/bin/env python3
"""Verify native account status in a release without operator credentials."""

from pathlib import Path
import subprocess
import sys
import tempfile


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: codex_subscription_smoke.py <bundled-loomd>")
    server = Path(sys.argv[1]).resolve(strict=True)
    with tempfile.TemporaryDirectory(prefix="loom-chatgpt-smoke-") as temporary:
        root = Path(temporary)
        home = root / "home"
        config = root / "config"
        home.mkdir(mode=0o700)
        config.mkdir(mode=0o700)
        # The native command uses the bundled runtime with no development OTP
        # on PATH. Its home and profile root contain no operator credentials.
        result = subprocess.run(
            [str(server), "codex", "status", "--profile", "smoke"],
            capture_output=True,
            cwd="/",
            env={"HOME": str(home), "XDG_CONFIG_HOME": str(config), "PATH": "/usr/bin:/bin"},
            timeout=30,
            check=True,
        )
        if result.stderr:
            raise AssertionError("native status wrote unexpected diagnostics")
        if result.stdout != b"Not signed in with ChatGPT.\n":
            raise AssertionError("native status did not report the redacted logged-out state")
        if list(root.rglob("*.json")):
            raise AssertionError("native status created credentials while logged out")
        profile = config / "loom/chatgpt-subscription"
        if not profile.is_dir() or profile.stat().st_mode & 0o077:
            raise AssertionError("native status did not use a private profile directory")
    print("ChatGPT: native release reports logged out without credentials")


if __name__ == "__main__":
    main()
