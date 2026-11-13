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

  # The executor records the tip it applied last and answers a repeat without
  # touching the tree. Without that, a request that arrives late, after the child
  # began to work, applies the seed over the child's commits.
  "M3-executor-reapplies-its-tip": ("tcOnlyNoOlderOverNewer", 8000, r"older tip", [
    ("PSrc/Exec.p",
     "    if (lastApplied == applyTip) {",
     "    if (false) {")]),

  # An apply of a tip the executor applied before touches nothing. A tree that
  # seeds again on a repeated request applies the state twice.
  "M4-apply-twice": ("tcOnlyAppliedOnce", 8000, r"applied to the same scope twice", [
    ("PSrc/Exec.p",
     "      announce eApplyRepeated;\n    } else {",
     "      announce eApplyRepeated;\n      announce eSeedEffective;\n    } else {")]),

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

  # The join, and a join asked again, end the child's session once the answer is
  # kept. Without that, a settled child keeps its session.
  "M9-join-keeps-the-session": ("tcOnlyReleased", 4000, r"liveness bug", [
    ("PSrc/Orch.p",
     "    announce eSettled, tip;\n    releaseSession();\n    toOwner(R_FINISHED, tip, arrived, desc);",
     "    announce eSettled, tip;\n    toOwner(R_FINISHED, tip, arrived, desc);"),
    ("PSrc/Orch.p",
     "      announce eRepeated;\n      releaseSession();",
     "      announce eRepeated;")]),

  # An ask that finds a verdict ends the session. Without that, an ask that
  # arrives between the verdict and the end of the session is answered and the
  # session is lost to a restart that comes before the step that ends it.
  "M19-ask-that-finds-a-verdict-keeps-the-session": ("tcOnlyReleasedRefused", 8000, r"liveness bug", [
    ("PSrc/Orch.p",
     "      releaseSession();\n      toOwner(R_REFUSED, 0, 0, 0);\n      return;",
     "      toOwner(R_REFUSED, 0, 0, 0);\n      return;")]),

  # A refusal's session is ended in the step after the verdict. Without that, a
  # refused child keeps its session.
  "M10-refused-child-keeps-its-session": ("tcOnlyReleasedRefused", 4000, r"liveness bug", [
    ("PSrc/Orch.p",
     "        releaseSession();\n        if (askerWaiting) {\n          askerWaiting = false;\n          toOwner(R_REFUSED, 0, 0, 0);",
     "        if (askerWaiting) {\n          askerWaiting = false;\n          toOwner(R_REFUSED, 0, 0, 0);")]),

  # The claim is let go whatever the end. A transient failure that keeps it leaves
  # every later ask told to ask again.
  "M11-claim-kept-after-a-failure": ("tcOnlySpawnEnds", 4000, r"liveness bug", [
    ("PSrc/Orch.p",
     "    announce eTransient, why;\n    claim = false;",
     "    announce eTransient, why;")]),

  # A join asked again after the child settled is answered from the entry kept
  # before the session was ended. Today's code before this change refused it,
  # because the session was gone.
  "M12-join-answer-not-kept": ("tcOnlyJoinRepeat", 4000, r"was refused", [
    ("PSrc/Orch.p",
     "    if (resultStored) {\n      announce eRepeated;",
     "    if (false) {\n      announce eRepeated;")]),

  # A store with no room for the commits is a request to ask again. Taken as the
  # end of the matter, the join settles with nothing and the commits are lost.
  "M13-return-lost-on-a-full-store": ("tcOnlyReturnOnce", 6000, r"liveness bug", [
    ("PSrc/Orch.p",
     "        announce eStoreFull;\n        toOwner(R_PENDING, 0, 0, 0);",
     "        announce eStoreFull;\n        announce eSettled, m.a;\n        releaseSession();\n        toOwner(R_FINISHED, 0, 0, 0);")]),

  # The owner makes one ref from the commits, however many replies carry them.
  "M14-ref-made-twice": ("tcOnlyReturnOnce", 6000, r"twice", [
    ("PSrc/Owner.p",
     "      if (stage == 1) {\n        if (m.b == m.c) {",
     "      if (stage >= 1) {\n        if (m.b == m.c) {"),
    ("PSrc/Owner.p",
     "          if (!refApplied) {",
     "          if (true) {")]),

  # A join is answered only for a child whose run has ended. Without the check the
  # commits are captured and the session ended under a running child.
  "M15-release-while-running": ("tcOnlyNoEarlyRelease", 6000, r"while its child was running", [
    ("PSrc/Orch.p",
     "    if (!finished || claim || joining) {",
     "    if (claim || joining) {")]),

  # The settled answer is kept before the session is ended.
  "M16-release-before-keeping": ("tcOnlyNoEarlyRelease", 6000, r"before its settled answer was kept", [
    ("PSrc/Orch.p",
     "    announce eSettleBegan;\n    resultStored = true;",
     "    announce eSettleBegan;\n    releaseSession();\n    resultStored = true;")]),

  # A second apply of the state being applied joins the run. Starting its own is
  # what ran two checkouts over one tree.
  "M17-second-apply-runs-its-own": ("tcOnlyOneApply", 6000, r"two checkouts", [
    ("PSrc/Exec.p",
     "        announce eApplyJoined;",
     "        announce eApplyStarted;")]),

  # The children are stopped first. Behind the pair's session, a spawner at its cap
  # leaves the children running.
  "M18-run-end-behind-the-pairs-session": ("tcOnlyRunEnd", 6000, r"left a child running", [
    ("PSrc/Orch.p",
     "    // The children first.\n",
     "    if (plan.pairFull) {\n      announce eRunEndHandled, (begun && !finished);\n      return;\n    }\n")]),

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
    # The checker runs more than one strategy and reports each, so the bug counts
    # are taken together.
    bugs = re.findall(r"Found (\d+) bug", out)
    found = max([int(each) for each in bugs]) if bugs else 0
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
