// Test cases.
//
// The `tc*` cases without `Probe` in the name must pass. The system cases check
// every spec over a mix of faults; the `tcOnly*` cases check one spec each over
// the same traffic, so a mutation (mutate.py) is reported under the name of the
// rule it breaks.
//
// The `tcProbe*` cases must fail: each finds a witness for a situation the specs
// are only meaningful if the model reaches.

module System = { Wire, Port, Laptop, SpawnCall, Chaos, Harness };

// Three call sites in two parent runs, all detached as phase 1 spawns them.
// Sites 0 and 2 derive one name, so the adoption check has a collision to
// refuse. Site 1 shares run 0 with site 0.
fun detached(): seq[tPlanSite] {
  var s: seq[tPlanSite];
  s += (0, (site = 0, run = 0, owner = -1));
  s += (1, (site = 1, run = 0, owner = -1));
  s += (2, (site = 2, run = 1, owner = -1));
  return s;
}

// The same sites with each child attached to its parent run, which no phase 1
// spawn is. The phase 2 `Release` is the sender these cases stand in for.
fun attached(): seq[tPlanSite] {
  var s: seq[tPlanSite];
  s += (0, (site = 0, run = 0, owner = 0));
  s += (1, (site = 1, run = 0, owner = 0));
  s += (2, (site = 2, run = 1, owner = 1));
  return s;
}

fun bothRuns(): seq[int] {
  var e: seq[int];
  e += (0, 0);
  e += (1, 1);
  return e;
}

fun noRuns(): seq[int] {
  var e: seq[int];
  return e;
}

machine TestQuiet {
  start state Init {
    entry {
      new Harness((sites = detached(), breaks = 0, crashes = 0, aborts = 0, ends = noRuns(), finishes = 0, pokes = 0, deletes = 0, drains = 0));
    }
  }
}

// Messages lost to dropped connections, with the drainer resending.
machine TestDrops {
  start state Init {
    entry {
      new Harness((sites = detached(), breaks = 3, crashes = 0, aborts = 0, ends = noRuns(), finishes = 0, pokes = 2, deletes = 0, drains = 0));
    }
  }
}

// The parent run is aborted while its spawns are in flight, and the drainer
// resends from the stubs.
machine TestAbort {
  start state Init {
    entry {
      new Harness((sites = detached(), breaks = 0, crashes = 0, aborts = 1, ends = noRuns(), finishes = 0, pokes = 2, deletes = 0, drains = 0));
    }
  }
}

// The remote restarts, twice, with a child finishing and the drainer resending.
machine TestRestart {
  start state Init {
    entry {
      new Harness((sites = detached(), breaks = 1, crashes = 2, aborts = 0, ends = noRuns(), finishes = 1, pokes = 2, deletes = 0, drains = 0));
    }
  }
}

// Every phase 1 fault together.
machine TestAll {
  start state Init {
    entry {
      new Harness((sites = detached(), breaks = 2, crashes = 1, aborts = 1, ends = noRuns(), finishes = 1, pokes = 2, deletes = 0, drains = 0));
    }
  }
}

// Phase 2 traffic: both parent runs end, with the end overtaking, repeating or
// following the spawns, and with drops, an abort and a resend in the mix.
machine TestRunEnd {
  start state Init {
    entry {
      new Harness((sites = attached(), breaks = 1, crashes = 0, aborts = 1, ends = bothRuns(), finishes = 0, pokes = 2, deletes = 0, drains = 0));
    }
  }
}

// The parent session is deleted while its children may be running, so the
// laptop owes the remote a `Release`. The `Release` is lost to dropped
// connections, overtakes the spawns it concerns, repeats, and follows the
// remote's restart, with the slot draining at any point.
machine TestRelease {
  start state Init {
    entry {
      new Harness((sites = detached(), breaks = 2, crashes = 1, aborts = 1, ends = noRuns(), finishes = 1, pokes = 2, deletes = 1, drains = 1));
    }
  }
}

test tcQuiet [main = TestQuiet]:
  assert AtMostOneChildPerSite, OwnChildOnly, AnswerIsStable, JoinReportsOwnChild, TerminalOnce, EveryStubAnswered, EveryChildTerminal in
  (union System, { TestQuiet });

test tcDrops [main = TestDrops]:
  assert AtMostOneChildPerSite, OwnChildOnly, AnswerIsStable, JoinReportsOwnChild, TerminalOnce, EveryStubAnswered, EveryChildTerminal in
  (union System, { TestDrops });

test tcAbort [main = TestAbort]:
  assert AtMostOneChildPerSite, OwnChildOnly, AnswerIsStable, JoinReportsOwnChild, TerminalOnce, EveryStubAnswered, EveryChildTerminal in
  (union System, { TestAbort });

test tcRestart [main = TestRestart]:
  assert AtMostOneChildPerSite, OwnChildOnly, AnswerIsStable, JoinReportsOwnChild, TerminalOnce, EveryStubAnswered, EveryChildTerminal in
  (union System, { TestRestart });

test tcAll [main = TestAll]:
  assert AtMostOneChildPerSite, OwnChildOnly, AnswerIsStable, JoinReportsOwnChild, TerminalOnce, EveryStubAnswered, EveryChildTerminal in
  (union System, { TestAll });

test tcRunEnd [main = TestRunEnd]:
  assert AtMostOneChildPerSite, OwnChildOnly, AnswerIsStable, JoinReportsOwnChild, TerminalOnce, NoSpawnUnderEndedRun, EndedRunChildrenStop, EveryStubAnswered, EveryChildTerminal in
  (union System, { TestRunEnd });

test tcRelease [main = TestRelease]:
  assert AtMostOneChildPerSite, OwnChildOnly, AnswerIsStable, JoinReportsOwnChild, TerminalOnce, ReleasedSessionHasNoRunningChild, ReleaseMakesNoSession, EveryReleaseIsTold, EveryStubAnswered, EveryChildTerminal in
  (union System, { TestRelease });

// One spec each, for mutate.py.
test tcOnlyOwnChild [main = TestQuiet]:
  assert OwnChildOnly in (union System, { TestQuiet });

test tcOnlyAtMostOneChild [main = TestAll]:
  assert AtMostOneChildPerSite in (union System, { TestAll });

test tcOnlyJoinReportsOwnChild [main = TestAll]:
  assert JoinReportsOwnChild in (union System, { TestAll });

test tcOnlyNoSpawnUnderEndedRun [main = TestRunEnd]:
  assert NoSpawnUnderEndedRun in (union System, { TestRunEnd });

test tcOnlyEndedRunChildrenStop [main = TestRunEnd]:
  assert EndedRunChildrenStop in (union System, { TestRunEnd });

test tcOnlyEveryChildTerminal [main = TestQuiet]:
  assert EveryChildTerminal in (union System, { TestQuiet });

test tcOnlyEveryStubAnswered [main = TestAbort]:
  assert EveryStubAnswered in (union System, { TestAbort });

test tcOnlyReleasedSession [main = TestRelease]:
  assert ReleasedSessionHasNoRunningChild in (union System, { TestRelease });

test tcOnlyReleaseMakesNoSession [main = TestRelease]:
  assert ReleaseMakesNoSession in (union System, { TestRelease });

test tcOnlyReleaseIsTold [main = TestRelease]:
  assert EveryReleaseIsTold in (union System, { TestRelease });

// Each of these must report a bug.
test tcProbeAdoption [main = TestAbort]:
  assert ProbeAdoption in (union System, { TestAbort });

test tcProbeCollisionRefused [main = TestQuiet]:
  assert ProbeCollisionRefused in (union System, { TestQuiet });

test tcProbeFenceRefused [main = TestRunEnd]:
  assert ProbeFenceRefused in (union System, { TestRunEnd });

test tcProbeChildLost [main = TestRestart]:
  assert ProbeChildLost in (union System, { TestRestart });

test tcProbeChildStopped [main = TestQuiet]:
  assert ProbeChildStopped in (union System, { TestQuiet });

test tcProbeJoinSettled [main = TestAll]:
  assert ProbeJoinSettled in (union System, { TestAll });

test tcProbeReleaseStopped [main = TestRelease]:
  assert ProbeReleaseStopped in (union System, { TestRelease });

test tcProbeReleaseRefusedSpawn [main = TestRelease]:
  assert ProbeReleaseRefusedSpawn in (union System, { TestRelease });

test tcProbeReleaseFoundNoSession [main = TestRelease]:
  assert ProbeReleaseFoundNoSession in (union System, { TestRelease });

test tcProbeSessionDeleted [main = TestRelease]:
  assert ProbeSessionDeleted in (union System, { TestRelease });
