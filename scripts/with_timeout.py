#!/usr/bin/env python3
"""Bound a test command independently of its language runtime's timers."""

import argparse
import math
import os
import signal
import subprocess
import sys
import time


def positive_seconds(value):
    seconds = float(value)
    if not math.isfinite(seconds) or seconds <= 0:
        raise argparse.ArgumentTypeError("timeout must be finite and positive")
    return seconds


def command_for_host(command):
    # The assertion ends with this command; it changes no persistent setting
    # and does not prevent an explicit user sleep or lid-close sleep.
    if sys.platform == "darwin":
        return ["/usr/bin/caffeinate", "-i", *command]
    return command


def run(command, seconds, cwd=None):
    started = time.monotonic()
    wall_started = time.time()
    print(f"test command: {command[0]} (deadline {seconds:g}s)", flush=True)
    child = subprocess.Popen(command_for_host(command), cwd=cwd,
                             start_new_session=True)
    try:
        while True:
            # A wall deadline catches time spent suspended on hosts whose
            # monotonic clock pauses in sleep. The monotonic deadline also
            # prevents a backwards wall-clock adjustment extending the run.
            elapsed = max(time.monotonic() - started, time.time() - wall_started)
            remaining = seconds - elapsed
            if remaining <= 0:
                raise subprocess.TimeoutExpired(command, seconds)
            try:
                status = child.wait(timeout=min(remaining, 1))
                elapsed = max(time.monotonic() - started,
                              time.time() - wall_started)
                if elapsed > seconds:
                    print("TIMEOUT: command completed beyond its wall deadline",
                          file=sys.stderr, flush=True)
                    return 124
                print(f"test command finished: exit={status}, elapsed={elapsed:.2f}s",
                      flush=True)
                return status if status >= 0 else 128 - status
            except subprocess.TimeoutExpired:
                continue
    except subprocess.TimeoutExpired:
        print(f"TIMEOUT after {seconds:g}s: terminating test process group "
              f"{child.pid}; inspect the last named test in the log",
              file=sys.stderr, flush=True)
        return 124
    finally:
        # Do not reap the group leader before signalling its group: its PID
        # must remain reserved while it names the group we created. Only an
        # unfinished command is killed; successful commands keep their status.
        if child.returncode is None:
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                print("test process did not reap after SIGKILL; cleanup is unconfirmed",
                      file=sys.stderr, flush=True)


def interrupted(signum, _frame):
    raise SystemExit(128 + signum)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("seconds", type=positive_seconds)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command
    if command[:1] == ["--"]:
        command = command[1:]
    if not command:
        parser.error("a command is required")
    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    return run(command, args.seconds)


if __name__ == "__main__":
    sys.exit(main())
