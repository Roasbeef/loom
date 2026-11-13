#!/usr/bin/env python3
"""Mutation checks for the seeded spawn model.

Each entry in MUTATIONS reintroduces one bug the Gleam code guards against, as
exact text replacements in the model sources, together with the test case that
must catch it and the text of the assertion it must trip. The script applies
one mutation, compiles, runs the test case, reports the first error, and
restores the sources whatever happens.

Run it from this directory:

    python3 mutate.py M1-spawn-before-apply
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
LOG = "PCheckerOutput/BugFinding/SeededSpawn_0_0.txt"

# name -> (test case, schedules, regex the assertion message must match, edits)
MUTATIONS = {
  # `land` returns to the Agency only after the executor confirmed the apply. A
  # spawn made before the apply request starts the child on an empty workspace.
  "M1-spawn-before-apply": ("tcOnlyFirstTurn", 2000, r"before the seed was applied", [
    ("PSrc/Orch.p",
     "    phase = PH_APPLY;\n    toExec(X_APPLY, 1, inc, token);",
     "    spawnChild();\n    phase = PH_APPLY;\n    toExec(X_APPLY, 1, inc, token);")]),

  # The registry creates a session under a request key, so a retry after a restart
  # finds the session it made. Keyed by whether it is resident, a restart makes a
  # second one.
  "M2-session-not-keyed": ("tcOnlyOneSession", 4000, r"second delegate session", [
    ("PSrc/Orch.p",
     "    if (!session) {\n      session = true;",
     "    if (!resident) {\n      session = true;")]),

  # The session is asked whether it has begun at the moment before the apply.
  # Without that check a retried land after a restart sends the seed over the
  # child's work.
  "M3-apply-without-begun-check": ("tcOnlyNoOlderOverNewer", 6000, r"older tip", [
    ("PSrc/Orch.p",
     "    if (fr == FR_BEGUN) {\n      announce eGate, begun;\n      finishPass();",
     "    if (false) {\n      announce eGate, begun;\n      finishPass();")]),

  # An apply of the tip the tree already has touches nothing. A tree that seeds
  # again on a repeated request applies the state twice.
  "M4-apply-twice": ("tcOnlyAppliedOnce", 4000, r"applied to the same scope twice", [
    ("PSrc/Exec.p",
     "        if (tip == 0) {\n          announce eSeedEffective;",
     "        if (tip == 0 || tip == m.a) {\n          announce eSeedEffective;")]),

  # The join answers only a bundle whose size is the one its description names, and
  # the owner makes its ref only from such a bundle. With neither check a short
  # capture becomes the owner's ref.
  "M5-ref-from-a-short-bundle": ("tcOnlyRefDescribed", 4000, r"not the one described", [
    ("PSrc/Orch.p",
     "      if (m.b != m.c) {",
     "      if (false) {"),
    ("PSrc/Owner.p",
     "        if (m.b == m.c) {",
     "        if (true) {")]),

  # Review finding 2 as it stood: an executor with no room was kept as a refusal.
  "M6-no-room-is-a-verdict": ("tcOnlyVerdict", 4000, r"permanent verdict", [
    ("PSrc/Orch.p",
     "        transient(W_NOROOM);",
     "        refuse(W_NOROOM);")]),

  # Review finding 2 as it stood: a stale fence was kept as a refusal.
  "M7-stale-fence-is-a-verdict": ("tcOnlyVerdictRestart", 4000, r"permanent verdict", [
    ("PSrc/Orch.p",
     "        transient(W_STALE);",
     "        refuse(W_STALE);")]),

  # Review finding 1 as it stood: a record that cannot be read answered `begun`.
  "M8-unreadable-is-begun": ("tcOnlyUnreadable", 4000, r"taken for one that had", [
    ("PSrc/Orch.p",
     "      return FR_UNREADABLE;",
     "      return FR_BEGUN;")]),

  # A verdict is answered at once, and the ask that finds it ends the session a
  # restart left behind. Without that, a refused child keeps its session.
  "M9-refused-child-keeps-its-session": ("tcOnlyReleasedRefused", 4000, r"liveness bug", [
    ("PSrc/Orch.p",
     "    if (verdict) {\n      releaseSession();\n",
     "    if (verdict) {\n")]),

  # The claim is let go whatever the end. A transient failure that keeps it leaves
  # every later ask told to ask again.
  "M10-claim-kept-after-a-failure": ("tcOnlySpawnEnds", 4000, r"liveness bug", [
    ("PSrc/Orch.p",
     "    announce eTransient, why;\n    claim = false;",
     "    announce eTransient, why;")]),
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
