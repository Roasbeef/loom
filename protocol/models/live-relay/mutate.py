#!/usr/bin/env python3
"""Mutation checks for the live session relay model.

Each entry in MUTATIONS reintroduces one bug the design guards against, as exact
text replacements in the model sources, together with the test case that must
catch it and the text of the assertion it must trip. The script applies one
mutation, compiles, runs the test case, reports the first error, and restores
the sources whatever happens.

Run it from this directory:

    python3 mutate.py M1-queue-drops-before-ack
    python3 mutate.py M2-repeated-piece-forwarded-again 4000
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

os.chdir(os.path.dirname(os.path.abspath(__file__)))

P = os.path.expanduser("~/.dotnet/tools/p")
LOG = "PCheckerOutput/BugFinding/LiveRelay_0_0.txt"

# name -> (test case, schedules, regex the assertion message must match, edits)
MUTATIONS = {
  # The queue drops frames only when a later poll's `after` acknowledges them.
  # Here the answer empties the queue, so an answer the link loses takes its
  # frames with it, and the next frame the laptop sees is numbered past a gap.
  "M1-queue-drops-before-ack": ("tcOnlyOrderedAtMostOnce", 4000, r"dropped a frame before", [
    ("PSrc/FeedHost.p",
     "    // The queue is kept until a later poll acknowledges it.\n",
     "    queue = default(seq[tFrame]);\n    qbytes = 0;\n")]),

  # A piece the box already admitted is answered again and changes nothing. Here
  # a repeat of a frame's last piece is handed to the filter again, so a request
  # the link duplicates, or a piece resent after its answer was lost, reaches
  # the gateway twice.
  "M2-repeated-piece-forwarded-again": ("tcOnlyOnceWhole", 4000, r"received frame \d+ twice", [
    ("PSrc/FeedHost.p",
     "      // A repeated piece changes nothing and is answered again.\n",
     "      if (m.cmd == CMD_FORWARD && m.offset + 1 == m.total) {\n        send gateway, eGwFrame, (n = m.n, cmd = m.cmd, pieces = m.total, total = m.total);\n      }\n")]),

  # A lapse drops the queue, and an ended feed answers its polls with no frames.
  # Here the lapse keeps the queue and the poll that learns of the ending is
  # answered with it.
  "M3-answers-frames-after-a-lapse": ("tcOnlyNothingAfterEnd", 1000, r"after its feed ended|reports the feed ended", [
    ("PSrc/FeedHost.p",
     "    queue = default(seq[tFrame]);\n    qbytes = 0;\n    recvOff = 0;\n",
     "    recvOff = 0;\n"),
    ("PSrc/FeedHost.p",
     "answerPoll(m.pollId, leftover(), ended);",
     "answerPoll(m.pollId, queue, ended);")]),

  # An `approve` goes to the hub's relayed door. Here the feed host calls the
  # local door, which judges it as the box owner's and with no ceiling.
  "M4-approve-to-the-local-door": ("tcOnlyRelayedDoor", 4000, r"local door", [
    ("PSrc/FeedHost.p",
     "send gateway, eRelayedDecide, (src = this, n = n);",
     "send gateway, eLocalApprove, this;")]),

  # The lease is longer than any partition the lane survives. Here it is shorter
  # than the partition of the liveness case, so the feed lapses while the link
  # is cut for less than the real lease.
  # Every ending detaches the gateway door once. Here a lapse ends the feed and
  # leaves the gateway's attachment, and its presence, behind.
  "M6-a-lapse-leaves-the-gateway-attached": ("tcOnlyDetachOnce", 1000, r"(liveness|hot state|Owing)", [
    ("PSrc/FeedHost.p",
     "    send gateway, eGwDetach;\n    ended = kind;\n",
     "    if (kind != EN_LAPSED) {\n      send gateway, eGwDetach;\n    }\n    ended = kind;\n")]),

  # An ended feed keeps its process and its permit until it is forgotten, so it
  # holds its place until then. Here the place is freed when the feed ends, and a
  # feed that attaches while the ended ones are kept makes more feeds alive than
  # the cap allows.
  "M7-an-ended-feed-frees-its-place-at-once": ("tcOnlyCap", 1000, r"more feeds are alive", [
    ("PSrc/FeedHost.p",
     "    if (directory != null) {\n      send directory, eFeedGone;\n    }\n    announce eFeedExited;\n",
     "    announce eFeedExited;\n"),
    ("PSrc/FeedHost.p",
     "    announce eFeedEnded, kind;\n",
     "    announce eFeedEnded, kind;\n    if (directory != null) {\n      send directory, eFeedGone;\n    }\n")]),

  "M5-lease-lapses-in-a-short-partition": ("tcOnlyShortPartition", 4000, r"(ended during a partition|hot state)", [
    ("PSrc/Types.p",
     "fun Lease(): int { return 10; }",
     "fun Lease(): int { return 3; }")]),

  # An answer that reports the feed ended delivers no frame. The box here is not
  # honest and answers its ending with the frames it had; the adapter that
  # delivers them breaks the rule, and only the laptop's side can be at fault
  # because the box's own check is blind in this case.
  "M8-delivers-the-frames-of-an-ended-answer": ("tcOnlyHostileEnd", 4000, r"reports the feed ended", [
    ("PSrc/UiFeed.p",
     "    if (end == 0) {\n      foreach",
     "    if (true) {\n      foreach")]),

  # A link that is only down shows waiting. Here the adapter always shows a
  # failure when the lane closes the page.
  "M9-shows-a-failure-for-a-link-that-is-down": ("tcOnlyDownWaiting", 4000, r"failure for a link that was only down", [
    ("PSrc/UiFeed.p",
     "    if (down == 1) {\n      return SH_WAITING;\n    }\n",
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
    if os.path.exists(LOG):
      os.remove(LOG)
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
