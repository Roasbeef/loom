#!/usr/bin/env python3
"""Mutation checks for the remote execution model.

Each entry in MUTATIONS reintroduces one bug the Gleam code guards against, as
exact text replacements in the model sources, together with the test case that
must catch it and the text of the assertion it must trip. The script applies
one mutation, compiles, runs the test case, reports the first error, and
restores the sources whatever happens.

Run it from this directory:

    python3 mutate.py M1-host-ignores-token
    python3 mutate.py M5-reply-before-commit 40000
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
LOG = "PCheckerOutput/BugFinding/RemoteExecution_0_0.txt"

# name -> (test case, schedules, regex the assertion message must match, edits)
MUTATIONS = {
  # exec_ledger.require_current compares the token inside the admitting
  # transaction. Without the comparison a dead open's Run starts a body.
  "M1-host-ignores-token": ("tcOnlyStaleToken", 4000, r"while the scope held", [
    ("PSrc/Host.p",
     "    if (m.token != scopeToken) {",
     "    if (false) {")]),

  # host.cancels_run: noconnection must not cancel. Here it does.
  "M2-noconnection-cancels": ("tcOnlyCancelOnAbort", 4000, r"because the connection dropped", [
    ("PSrc/Host.p",
     "    return !noconn;",
     "    return true;")]),

  # surface.recover asks a ReplayNever call with QueryOrFence. Here it asks
  # with a plain Query, which leaves a window for the dead runtime's Run.
  "M3-recover-never-with-query": ("tcOnlyNoStartAfterFence", 10000, r"(started after the key was fenced|reported as not started)", [
    ("PSrc/Call.p",
     "    m.fence = replay == REPLAY_NEVER;",
     "    m.fence = false;")]),

  # host.admit_run joins a live key. Here it starts a second run for it.
  "M4-second-run-for-admitted-key": ("tcOnlyAtMostOnceJoin", 20000, r"started twice", [
    ("PSrc/Host.p",
     "        joinRun(m);\n",
     "        startRun(m);\n")]),

  # host.run_finished commits before any reply. Here the reply goes first and
  # the commit is a later step of the same VM, which a crash can overtake.
  "M5-reply-before-commit": ("tcOnlyOutcomeFaithful", 40000, r"(no terminal row|the ledger stored)", [
    ("PSrc/Host.p",
     "    ledger[key] = (phase = ROW_TERMINAL, outcome = bodyOutcome(key));\n"
     "    announce eTerminal, (key = key, outcome = bodyOutcome(key));\n"
     "    foreach (w in l.waiters) {\n"
     "      send wire, eSend, (sender = this, msg = answerTo(w, key, ANS_FINISHED, bodyOutcome(key)));\n"
     "    }\n"
     "    live -= (key);\n",
     "    foreach (w in l.waiters) {\n"
     "      send wire, eSend, (sender = this, msg = answerTo(w, key, ANS_FINISHED, bodyOutcome(key)));\n"
     "    }\n"
     "    live -= (key);\n"
     "    send this, eLateCommit, (key = key, inc = incarnation);\n"),
    ("PSrc/Host.p",
     "    on eNoConn do {\n      connectionLost();\n    }\n",
     "    on eNoConn do {\n      connectionLost();\n    }\n\n"
     "    on eLateCommit do (c: (key: tKey, inc: int)) {\n"
     "      if (c.inc == incarnation) {\n"
     "        ledger[c.key] = (phase = ROW_TERMINAL, outcome = bodyOutcome(c.key));\n"
     "        announce eTerminal, (key = c.key, outcome = bodyOutcome(c.key));\n"
     "      }\n"
     "    }\n"),
    ("PSrc/Host.p",
     "  var nextJob: int;\n",
     "  var nextJob: int;\n  var incarnation: int;\n"),
    ("PSrc/Host.p",
     "    placed = false;\n    live = default",
     "    placed = false;\n    incarnation = incarnation + 1;\n    live = default"),
    ("PSrc/Types.p",
     "event eStep;\n",
     "event eStep;\nevent eLateCommit: (key: tKey, inc: int);\n")]),

  # host.admit_run answers a key it holds a row for before it refuses for lack
  # of a plane. Here the plane is checked first, so a restarted executor
  # refuses a call it may have run.
  "M6-plane-checked-before-ledger": ("tcDefectNoPlane", 4000, r"told the executor refused", [
    ("PSrc/Host.p",
     "      if (m.key in ledger) {\n        answerFromRow(m);\n      } else {\n        reply(m, K_ANSWER, ANS_NOPLANE, LOOK_MISSING, 0);\n      }\n",
     "      reply(m, K_ANSWER, ANS_NOPLANE, LOOK_MISSING, 0);\n")]),

  # exec_ledger.ack leaves a tombstone that keeps the key taken. Here it deletes
  # the row, so a dead runtime's late Run, which carries the same attach token,
  # finds no row and starts a key that was fenced and acknowledged.
  "M7-ack-deletes-the-row": ("tcOnlyNoStartAfterAck", 20000, r"started after the key was fenced", [
    ("PSrc/Host.p",
     "      ledger[key] = (phase = ROW_ACKED, outcome = 0);\n",
     "      ledger -= (key);\n")]),

  # exec_ledger.stop_or_fence bars a key that has no row. Here a stop for a
  # missing key does nothing, so a start a dead worker sent before the record
  # closed arrives after the stop and starts the program.
  "M8-stop-does-not-fence": ("tcOnlyExecNoStartAfterStop", 20000, r"started after the host processed its stop", [
    ("PSrc/Host.p",
     "      ledger[key] = (phase = ROW_UNKNOWN, outcome = 0);\n"
     "      execs += (key);\n"
     "      announce eUnknown, key;\n"
     "      return;\n",
     "      return;\n")]),

  # surface.start_execution sends the same start again after a dropped
  # connection. Here the worker takes the break for a cancel and stops the
  # program, though nobody closed its record.
  "M9-noconnection-stops": ("tcOnlyExecStopOnlyOnDecision", 20000, r"stopped though its record was never closed", [
    ("PSrc/Execution.p",
     "    on eNoConn do {\n"
     "      resent = true;\n"
     "      sendStart();\n"
     "      resent = false;\n"
     "    }\n",
     "    on eNoConn do {\n"
     "      var m: tMsg;\n"
     "      m = default(tMsg);\n"
     "      m.kind = K_STOP;\n"
     "      m.dest = executor;\n"
     "      m.from = this;\n"
     "      m.key = key;\n"
     "      send wire, eSend, (sender = this, msg = m);\n"
     "    }\n")]),

  # workspace.settled_by_kind acknowledges an execution's row only once its
  # record is closed. Here every settled row is acknowledged, so a value the
  # worker has not read yet becomes a tombstone.
  "M10-settled-ignores-record": ("tcOnlyExecAckOnlyWhenRecordTerminal", 20000, r"acknowledged while its record was live", [
    ("PSrc/Execution.p",
     "    return !(key in phase) || phase[key] != P_LIVE;\n",
     "    return true;\n")]),

  # exec_ledger.open turns every admitted row unknown and relaunches nothing.
  # Here a restarted executor starts its running programs again.
  "M11-restart-relaunches": ("tcOnlyExecAtMostOnce", 20000, r"started twice", [
    ("PSrc/Host.p",
     "    foreach (k in ks) {\n"
     "      markUnknown(k);\n"
     "    }\n"
     "    placed = false;\n",
     "    foreach (k in ks) {\n"
     "      if (k in execs && ledger[k].phase == ROW_ADMITTED) {\n"
     "        announce eStart, (key = k, runToken = scopeToken, scopeToken = scopeToken);\n"
     "        nextJob = nextJob + 1;\n"
     "        new ExecBody((host = this, key = k, job = nextJob));\n"
     "      } else {\n"
     "        markUnknown(k);\n"
     "      }\n"
     "    }\n"
     "    placed = false;\n")]),

  # The reconciler stops a running program whose record is no longer live.
  # Here it skips the executions, so a program whose stop a partition lost runs
  # on forever.
  "M12-reconciler-skips-executions": ("tcOnlyEveryExecutionSettles", 40000, r"liveness bug", [
    ("PSrc/Execution.p",
     "    foreach (k in running) {\n"
     "      if (k in phase && phase[k] != P_LIVE) {\n"
     "        sendStop(k);\n"
     "      }\n"
     "    }\n",
     "")]),
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
