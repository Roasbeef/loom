#!/usr/bin/env python3
"""Mutation checks for the state transfer model.

Each entry in MUTATIONS reintroduces one bug the Gleam code guards against, as
exact text replacements in the model sources, together with the test case that
must catch it and the text of the assertion it must trip. The script applies
one mutation, compiles, runs the test case, reports the first error, and
restores the sources whatever happens.

Run it from this directory:

    python3 mutate.py M1-store-without-comparing
    python3 mutate.py --list
    python3 mutate.py --check

`--check` runs every mutation and exits non-zero if any survives, which is what
scripts/model_check.sh runs after the project's cases and probes. A mutation
that no longer applies (its pattern is not found exactly once) fails loudly
rather than running the unmutated model; update the pattern when the model's
text changes.
"""
import os
import re
import subprocess
import sys

P = os.path.expanduser("~/.dotnet/tools/p")
LOG = "PCheckerOutput/BugFinding/StateTransfer_0_0.txt"

# name -> (test case, schedules, regex the assertion message must match, edits)
MUTATIONS = {
  # state_store.finish compares the received bytes with the description before
  # it names them. Without the comparison a forged bundle is stored.
  "M1-store-without-comparing": ("tcOnlyStoredBytes", 2000, r"not the described state", [
    ("PSrc/Receiver.p",
     "    if (part == expected) {",
     "    if (true) {")]),

  # state_transfer.judge finishes only when the verdict holds the whole size.
  # Without the check the first accepted piece ends the transfer.
  "M2-delivered-on-any-acceptance": ("tcOnlyDelivery", 2000, r"before any record named the state", [
    ("PSrc/Sender.p",
     "        if (r.held >= size) {",
     "        if (true) {")]),

  # state_transfer.stage answers Complete only for a state with a record. A
  # store that answers it for any bytes held tells a resuming sender it is done.
  "M3-status-completes-on-any-bytes": ("tcOnlyDelivery", 2000, r"before any record named the state", [
    ("PSrc/Receiver.p",
     "    if (stored) {\n      reply(r, A_COMPLETE, size);",
     "    if (stored || sizeof(part) > 0) {\n      reply(r, A_COMPLETE, size);")]),

  # A restart keeps a prefix of the half-written file. A store that came back
  # with bytes the sender never sent breaks the prefix the append rule rests on.
  "M4-restart-invents-a-byte": ("tcOnlyPrefix", 4000, r"not a prefix", [
    ("PSrc/Receiver.p",
     "    part = shorter;\n  }",
     "    shorter += (sizeof(shorter), 0);\n    part = shorter;\n  }")]),
}


def run(args):
  return subprocess.run([P] + args, capture_output=True, text=True).stdout


def restore(backups):
  for path, src in backups.items():
    open(path, "w").write(src)


def attempt(name, schedules=None):
  """Applies one mutation and reports (caught, detail)."""
  test, default_schedules, expected, edits = MUTATIONS[name]
  schedules = schedules or default_schedules
  backups = {}
  try:
    for path, old, new in edits:
      if path not in backups:
        backups[path] = open(path).read()
      src = open(path).read()
      if src.count(old) != 1:
        return False, f"the pattern is not found exactly once in {path}; is the model already mutated?"
      open(path, "w").write(src.replace(old, new))
    out = run(["compile"])
    if "Compilation succeeded" not in out:
      return False, "COMPILE FAILED\n" + out[-2000:]
    out = run(["check", "-tc", test, "-s", str(schedules)])
    bugs = re.search(r"Found (\d+) bug", out)
    found = int(bugs.group(1)) if bugs else 0
    error = ""
    if found and os.path.exists(LOG):
      for line in open(LOG):
        if "<ErrorLog>" in line:
          error = line.strip()[:260]
          break
    if not found:
      return False, f"{test}: survived {schedules} schedules"
    if not re.search(expected, error):
      return False, f"{test}: caught by the wrong rule: {error}"
    return True, f"{test}: {error}"
  finally:
    restore(backups)
    run(["compile"])


def main():
  if len(sys.argv) == 2 and sys.argv[1] == "--list":
    print("\n".join(MUTATIONS))
    return 0
  if len(sys.argv) == 2 and sys.argv[1] == "--check":
    failed = 0
    for name in MUTATIONS:
      caught, detail = attempt(name)
      print(f"   {'ok  ' if caught else 'FAIL'} {name} ({detail})", flush=True)
      failed |= 0 if caught else 1
    return failed
  if len(sys.argv) < 2 or sys.argv[1] not in MUTATIONS:
    sys.exit("usage: mutate.py <mutation> [schedules] | --list | --check")
  schedules = int(sys.argv[2]) if len(sys.argv) > 2 else None
  caught, detail = attempt(sys.argv[1], schedules)
  print(f"{sys.argv[1]} {'caught' if caught else 'NOT CAUGHT'}: {detail}")
  return 0 if caught else 1


sys.exit(main())
