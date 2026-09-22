#!/usr/bin/env python3
"""Profile one existing generated Erlang module without replacing build output."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import tempfile
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("package", type=Path, help="Gleam package directory")
    parser.add_argument("module", help="Generated module name, such as tui")
    parser.add_argument("--mode", choices=("dev", "prod"), default="dev")
    parser.add_argument("--timeout", type=float, default=120)
    args = parser.parse_args()
    if not re.fullmatch(r"[a-z][a-zA-Z0-9_@]*", args.module):
        parser.error("module must be a generated Erlang module name, not a path")
    if not 0 < args.timeout <= 1200:
        parser.error("timeout must be greater than zero and at most 1200 seconds")
    build = args.package.resolve() / "build" / args.mode / "erlang"
    matches = list(build.glob(f"*/_gleam_artefacts/{args.module}.erl"))
    if len(matches) != 1:
        parser.error(f"expected one generated module under {build}; found {len(matches)}")
    compiler = shutil.which("erlc")
    if compiler is None:
        parser.error("erlc is unavailable on PATH")
    source = matches[0]
    output = Path(tempfile.mkdtemp(prefix="loom-compile-"))
    command = [compiler, "+time", "-o", str(output), "-I", str(source.parent.parent / "include")]
    for ebin in sorted(build.glob("*/ebin")):
        command.extend(("-pa", str(ebin)))
    command.append(str(source))
    metadata = {
        "source": str(source),
        "source_sha256": hashlib.sha256(source.read_bytes()).hexdigest(),
        "mode": args.mode,
        "command": command,
        "timeout_seconds": args.timeout,
    }
    print(f"Profile directory: {output}", flush=True)
    started = time.monotonic()
    timed_out = False
    with (output / "profile.log").open("w") as log:
        try:
            with subprocess.Popen(
                command, stdout=log, stderr=subprocess.STDOUT, start_new_session=True
            ) as process:
                try:
                    status = process.wait(timeout=args.timeout)
                except (subprocess.TimeoutExpired, KeyboardInterrupt) as error:
                    # The compiler driver may launch a BEAM child. Terminate
                    # only this invocation's process group before returning.
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait()
                    timed_out = isinstance(error, subprocess.TimeoutExpired)
                    status = 124 if timed_out else 130
        except OSError as error:
            log.write(f"Could not launch compiler: {error}\n")
            status = 127
    metadata.update(
        exit_code=status,
        timed_out=timed_out,
        wall_seconds=round(time.monotonic() - started, 3),
    )
    (output / "metadata.json").write_text(json.dumps(metadata, indent=2) + "\n")
    print(json.dumps({"exit_code": status, "timed_out": timed_out, "wall_seconds": metadata["wall_seconds"]}))
    return status if status >= 0 else 128 - status


if __name__ == "__main__":
    raise SystemExit(main())
