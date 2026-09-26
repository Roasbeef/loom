#!/usr/bin/env python3
"""Mutation checks for the terminal attachment model.

Each entry in MUTATIONS reintroduces one bug the Gleam code guards against,
as exact text replacements in the model sources. The script applies one
mutation, compiles, runs the named test cases, prints the first error each
test reports, and restores the sources whatever happens.

Run it from this directory:

    python3 mutate.py M5-drop-acknowledgement 10000 tcReplace
    python3 mutate.py --list

A mutation that no longer applies (its pattern is not found exactly once)
fails loudly rather than running the unmutated model; update the pattern
when the model's text changes.
"""
import subprocess, sys, re, os

P = os.path.expanduser("~/.dotnet/tools/p")

MUTATIONS = {
  "M1-adopt-before-completion": [("PSrc/Terminal.p",
    "    if (sizeof(outcomesBox[cand.outcomesInbox]) > 0) {\n      oq = outcomesBox",
    "    if (cand.captured) {\n      adoptCandidate();\n      return;\n    }\n    if (sizeof(outcomesBox[cand.outcomesInbox]) > 0) {\n      oq = outcomesBox")],
  "M2-read-old-inbox-after-swap": [("PSrc/Terminal.p",
    "    if (!hasLane || !(inbox in framesBox)) {\n      return;\n    }\n    while (sizeof(framesBox[inbox]) > 0) {",
    "    if (!hasLane || !(inbox in framesBox)) {\n      return;\n    }\n    drainOld();\n    while (sizeof(framesBox[inbox]) > 0) {"),
    ("PSrc/Terminal.p",
    "  // inbound.cancel_pending.\n",
    "  fun drainOld() {\n    var q: seq[tArrived];\n    var a: tArrived;\n    var before: tChan;\n    if (!(prevInbox in framesBox)) {\n      return;\n    }\n    while (sizeof(framesBox[prevInbox]) > 0) {\n      q = framesBox[prevInbox];\n      a = q[0];\n      q -= (0);\n      framesBox[prevInbox] = q;\n      announce eApplied, (source = a.sock,);\n      before = lane;\n      lane = chanReceive(lane, a.msg);\n      applyLaneUpdates(before, LOST_FAIL);\n    }\n  }\n\n  // inbound.cancel_pending.\n"),
    ("PSrc/Terminal.p",
    "  var unconfirmed: int;\n",
    "  var unconfirmed: int;\n  var prevInbox: int;\n"),
    ("PSrc/Terminal.p",
    "    hasLane = true;\n    lane = adopted.chan;\n    inbox = adopted.framesInbox;",
    "    hasLane = true;\n    lane = adopted.chan;\n    prevInbox = inbox;\n    inbox = adopted.framesInbox;"),
    ("PSrc/Terminal.p",
    "      outbox += (sizeof(outbox), (kind = EFF_DISCARD,",
    "      if (false) outbox += (sizeof(outbox), (kind = EFF_DISCARD,")],
  "M3-resend-after-reconnect": [("PSrc/Terminal.p",
    "    lane = chanAdmitRead(lane);\n  }",
    "    if (unconfirmed >= 0) {\n      lane = chanAdmitMutation(lane, unconfirmed);\n      lane.ups = default(seq[tUp]);\n      unconfirmed = -1;\n    }\n    lane = chanAdmitRead(lane);\n  }")],
  "M4-transmit-after-shut": [("PSrc/Channel.p",
    "  if (c.phase == CLOSED) {\n    return next;\n  }\n  next.phase = CLOSED;\n  next.queuedIntent = NO_INTENT;",
    "  if (c.phase == CLOSED) {\n    return next;\n  }\n  next.queuedIntent = NO_INTENT;")],
  "M16-close-closed-lane-shuts-again": [("PSrc/Channel.p",
    "  if (c.phase == CLOSED) {\n    return next;\n  }\n  next.phase = CLOSED;\n  next.queuedIntent = NO_INTENT;",
    "  next.phase = CLOSED;\n  next.queuedIntent = NO_INTENT;")],
  "M17-transport-loss-refails-closed-lane": [("PSrc/Channel.p",
    "    if (c.phase == CLOSED) {\n      return next;\n    }\n    return chanFail(c);",
    "    return chanFail(c);")],
  "M5-drop-acknowledgement": [("PSrc/Terminal.p",
    "      outbox += (sizeof(outbox), (kind = EFF_ACK,",
    "      if (false) outbox += (sizeof(outbox), (kind = EFF_ACK,")],
  "M6-retire-without-unknown": [("PSrc/Channel.p",
    "    if (next.ups[i].kind != UP_FAILED) {",
    "    if (next.ups[i].kind != UP_FAILED && next.ups[i].kind != UP_UNKNOWN) {")],
  "M7-notice-ignores-inflight": [("PSrc/Channel.p",
    "  if (c.phase == READY) {\n    next.due = false;\n    return chanCaptureAgain(next);\n  }\n  next.due = true;",
    "  if (true) {\n    next.due = false;\n    return chanCaptureAgain(next);\n  }\n  next.due = true;")],
  "M8-quit-forgets-candidate": [("PSrc/Terminal.p",
    "    if (cand.opening) {\n      outbox += (sizeof(outbox), (kind = EFF_ABANDON,",
    "    if (false) {\n      outbox += (sizeof(outbox), (kind = EFF_ABANDON,")],
  "M9-unsent-migrates-on-adoption": [("PSrc/Terminal.p",
    "    adopted = cand;\n    cand = idleCand();\n    cancelPending();\n    if (hasLane) {",
    "    adopted = cand;\n    cand = idleCand();\n    carried = -1;\n    if (hasLane && chanHasUnsent(lane)) {\n      carried = lane.queuedCmd;\n      lane.queuedIntent = NO_INTENT;\n      lane.queuedCmd = -1;\n    }\n    if (hasLane) {"),
    ("PSrc/Terminal.p",
    "    var adopted: tCand;\n    var before: tChan;",
    "    var adopted: tCand;\n    var carried: int;\n    var before: tChan;"),
    ("PSrc/Terminal.p",
    "    announce eVisible, (attempt = adopted.attempt, sock = lane.sock);\n",
    "    announce eVisible, (attempt = adopted.attempt, sock = lane.sock);\n    if (carried >= 0) {\n      lane = chanAdmitRead(lane);\n      lane.queuedIntent = MUTATION_INTENT;\n      lane.queuedCmd = carried;\n      return;\n    }\n")],
  "M10-ack-at-prepare": [("PSrc/Terminal.p",
    "    if (before.hasChan && !before.captured && cand.captured) {",
    "    if (cand.hasChan && !cand.captured && sizeof(cand.chan.out) > 0) {")],
  "M14-ack-at-prepare-and-adopt-unchecked": [("PSrc/Terminal.p",
    "    if (before.hasChan && !before.captured && cand.captured) {",
    "    if (cand.hasChan && !cand.captured && sizeof(cand.chan.out) > 0) {"),
    ("PSrc/Terminal.p",
    "    if (!cand.captured) {\n      failCandidate(cand);\n      return;\n    }\n\n    // connection.adopt",
    "    // connection.adopt")],
  "M15-quit-leaves-lane-open": [("PSrc/Terminal.p",
    "      lane = chanClose(lane);\n      if (before.phase != CLOSED) {\n        announce eLaneClosed, (sock = lane.sock, why = LOST_QUIT);",
    "      if (before.phase != CLOSED) {\n        announce eLaneClosed, (sock = lane.sock, why = LOST_QUIT);")],
  "M11-skip-discard": [("PSrc/Terminal.p",
    "      outbox += (sizeof(outbox), (kind = EFF_DISCARD,",
    "      if (false) outbox += (sizeof(outbox), (kind = EFF_DISCARD,")],
  "M12-quit-skips-cancel-pending": [("PSrc/Terminal.p",
    "    on eOpQuit do {\n      if (pending()) {\n        cancelPending();\n      } else {",
    "    on eOpQuit do {\n      if (false) {\n        cancelPending();\n      } else {")],
  "M13-tick-drains-before-adoption": [("PSrc/Terminal.p",
    "      tickPending = false;\n      pollCandidate(false);\n      drainLane();",
    "      tickPending = false;\n      drainLane();\n      pollCandidate(false);")],
}


def run(args):
  return subprocess.run([P] + args, capture_output=True, text=True).stdout


def main():
  if len(sys.argv) == 2 and sys.argv[1] == "--list":
    print("\n".join(MUTATIONS))
    return
  if len(sys.argv) < 4:
    sys.exit("usage: mutate.py <mutation> <schedules> <test>... | --list")
  name, schedules, tests = sys.argv[1], sys.argv[2], sys.argv[3:]
  backups = {}
  try:
    for path, old, new in MUTATIONS[name]:
      if path not in backups:
        backups[path] = open(path).read()
      src = open(path).read()
      assert src.count(old) == 1, f"{name}: pattern not unique in {path}"
      open(path, "w").write(src.replace(old, new))
    out = run(["compile"])
    if "Compilation succeeded" not in out:
      print(name, "COMPILE FAILED")
      print(out[-3000:])
      return
    for t in tests:
      out = run(["check", "-tc", t, "-s", schedules])
      bugs = re.search(r"Found (\d+) bug", out)
      sched = re.search(r"Explored (\d+) schedules", out)
      err = ""
      log = "PCheckerOutput/BugFinding/TerminalAttachment_0_0.txt"
      if bugs and bugs.group(1) != "0" and os.path.exists(log):
        for line in open(log):
          if "<ErrorLog>" in line:
            err = line.strip()[:260]
            break
      print(f"{name} {t}: bugs={bugs.group(1) if bugs else '?'} schedules={sched.group(1) if sched else '?'} {err}", flush=True)
  finally:
    for path, src in backups.items():
      open(path, "w").write(src)
    run(["compile"])


main()
