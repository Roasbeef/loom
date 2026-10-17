#!/usr/bin/env python3
"""Mutation checks for the remote subagents model.

Each entry in MUTATIONS reintroduces one bug the Gleam code guards against, as
exact text replacements in the model sources, together with the test case that
must catch it and the text of the assertion it must trip. The script applies
one mutation, compiles, runs the test case, reports the first error, and
restores the sources whatever happens.

Run it from this directory:

    python3 mutate.py M1-adopt-ignores-minted-by
    python3 mutate.py M2-resend-creates-second-child 20000
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
LOG = "PCheckerOutput/BugFinding/RemoteSubagents_0_0.txt"

# name -> (test case, schedules, regex the assertion message must match, edits)
MUTATIONS = {
  # The adoption check compares `minted_by` with the call site. Without the
  # comparison a call site whose name another site holds is answered with the
  # other site's child.
  "M1-adopt-ignores-minted-by": ("tcOnlyOwnChild", 4000, r"another call site minted", [
    ("PSrc/Port.p",
     "      if (children[c].mintedBy == m.site) {",
     "      if (true) {")]),

  # A resent `Spawn` finds the child its call site made and answers its handle.
  # Here the resend does not look, and creates a second child.
  "M2-resend-creates-second-child": ("tcOnlyAtMostOneChild", 20000, r"created a second child", [
    ("PSrc/Port.p",
     "    if (name in byName) {",
     "    if (name in byName && false) {")]),

  # Admission reads the ended fence before it creates a child. Here it does not.
  "M3-admission-ignores-fence": ("tcOnlyNoSpawnUnderEndedRun", 20000, r"which had ended", [
    ("PSrc/Port.p",
     "    if (m.run in fence) {",
     "    if (false) {")]),

  # `RunEnded` writes the fence and then stops the run's children. Here it stops
  # the children and writes no fence, so a spawn that arrives later creates one.
  "M4-run-ended-writes-no-fence": ("tcOnlyNoSpawnUnderEndedRun", 20000, r"which had ended", [
    ("PSrc/Port.p",
     "    fence += (run);\n",
     "")]),

  # `RunEnded` calls `reap_run`, which stops every child attached to the run.
  # Here it writes the fence and stops nothing.
  "M5-run-ended-reaps-nothing": ("tcOnlyEndedRunChildrenStop", 20000, r"still running after its end", [
    ("PSrc/Port.p",
     "      if (children[c].owner == run && children[c].st == CS_RUNNING) {\n        end(c, CS_STOPPED);\n      }\n",
     "")]),

  # The holder's tick calls `reap_overdue`. Here the tick stops nothing, so a
  # child nobody waits on runs past its deadline.
  "M6-tick-reaps-nothing": ("tcOnlyEveryChildTerminal", 4000, r"hot state", [
    ("PSrc/Port.p",
     "      if (children[c].st == CS_RUNNING && children[c].overdue) {\n        end(c, CS_STOPPED);\n      }\n",
     "")]),

  # The drainer resends the `Spawn` of every `Requested` stub. Here it does not,
  # so a spawn whose effect process was killed is never answered.
  "M7-drainer-does-not-resend": ("tcOnlyEveryStubAnswered", 4000, r"hot state", [
    ("PSrc/Laptop.p",
     "      if (stubs[s].st == ST_REQUESTED) {",
     "      if (false) {")]),

  # The drainer's join names the stub's own child. Here it names child zero, so
  # a call site can be told the result of another site's child.
  "M8-join-names-the-wrong-child": ("tcOnlyJoinReportsOwnChild", 20000, r"(another call site minted|did not reach)", [
    ("PSrc/Laptop.p",
     "dest = port, site = s, child = stubs[s].child,",
     "dest = port, site = s, child = 0,")]),
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
