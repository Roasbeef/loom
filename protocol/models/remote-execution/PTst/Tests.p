// Test cases.
//
// The `tc*` cases without `Probe` in the name must pass. The system cases
// check every safety spec and the liveness spec over a mix of faults; the
// `tcOnly*` cases check one spec each over the same traffic, so a mutation
// (mutate.py) is reported under the name of the rule it breaks.
//
// The `tcProbe*` cases must fail: each finds a witness for a situation the
// specs are only meaningful if the model reaches.
//
// `tcDefectNoPlane` and `tcDefectLateRun` are ordinary cases that were probes
// while the defects they name were open (README.md, "Defects found"). They
// pass now, and a mutant in mutate.py reopens each.

module System = { Wire, Host, Body, Orch, Call, Chaos, Harness };

// Two calls: one the planner may replay, one it may not.
fun mixed(): seq[tReplay] {
  var r: seq[tReplay];
  r += (0, REPLAY_NEVER);
  r += (1, REPLAY_SAFE);
  return r;
}

// Three calls, two of which are ReplayNever, for the fence.
fun fenced(): seq[tReplay] {
  var r: seq[tReplay];
  r += (0, REPLAY_NEVER);
  r += (1, REPLAY_NEVER);
  r += (2, REPLAY_SAFE);
  return r;
}

machine TestQuiet {
  start state Init {
    entry {
      new Harness((replays = mixed(), acks = ACK_AFTER_QUIET, breaks = 0, crashes = 0, opens = 0, restarts = 0));
    }
  }
}

machine TestPartition {
  start state Init {
    entry {
      new Harness((replays = mixed(), acks = ACK_AFTER_QUIET, breaks = 3, crashes = 0, opens = 0, restarts = 0));
    }
  }
}

machine TestOpenCrash {
  start state Init {
    entry {
      new Harness((replays = fenced(), acks = ACK_AFTER_QUIET, breaks = 1, crashes = 0, opens = 2, restarts = 0));
    }
  }
}

machine TestHostCrash {
  start state Init {
    entry {
      new Harness((replays = mixed(), acks = ACK_AFTER_QUIET, breaks = 1, crashes = 1, opens = 1, restarts = 0));
    }
  }
}

// Every fault: connection drops, an executor crash, an open ending and a
// runtime restart.
machine TestAll {
  start state Init {
    entry {
      new Harness((replays = fenced(), acks = ACK_AFTER_QUIET, breaks = 2, crashes = 1, opens = 1, restarts = 1));
    }
  }
}

// A runtime restart inside one open, with the open's token unchanged.
machine TestRuntimeRestart {
  start state Init {
    entry {
      new Harness((replays = fenced(), acks = ACK_AFTER_QUIET, breaks = 0, crashes = 0, opens = 0, restarts = 2));
    }
  }
}

// The same runtime restarts, with the acknowledgement sent as soon as the
// result is staged.
machine TestRuntimeRestartAckAtOnce {
  start state Init {
    entry {
      new Harness((replays = fenced(), acks = ACK_AT_ONCE, breaks = 0, crashes = 0, opens = 0, restarts = 2));
    }
  }
}

test tcQuiet [main = TestQuiet]:
  assert AtMostOnceStart, NoStartAfterFence, UnknownIsFinal, OutcomeFaithful, StaleTokenRefused, CancelOnlyOnAbort, EveryKeyDelivered in
  (union System, { TestQuiet });

test tcPartition [main = TestPartition]:
  assert AtMostOnceStart, NoStartAfterFence, UnknownIsFinal, OutcomeFaithful, StaleTokenRefused, CancelOnlyOnAbort, EveryKeyDelivered in
  (union System, { TestPartition });

test tcOpenCrash [main = TestOpenCrash]:
  assert AtMostOnceStart, NoStartAfterFence, UnknownIsFinal, OutcomeFaithful, StaleTokenRefused, CancelOnlyOnAbort, EveryKeyDelivered in
  (union System, { TestOpenCrash });

test tcHostCrash [main = TestHostCrash]:
  assert AtMostOnceStart, NoStartAfterFence, UnknownIsFinal, OutcomeFaithful, StaleTokenRefused, CancelOnlyOnAbort, EveryKeyDelivered in
  (union System, { TestHostCrash });

test tcRuntimeRestart [main = TestRuntimeRestart]:
  assert AtMostOnceStart, NoStartAfterFence, UnknownIsFinal, OutcomeFaithful, StaleTokenRefused, CancelOnlyOnAbort, EveryKeyDelivered in
  (union System, { TestRuntimeRestart });

test tcAll [main = TestAll]:
  assert AtMostOnceStart, NoStartAfterFence, UnknownIsFinal, OutcomeFaithful, StaleTokenRefused, CancelOnlyOnAbort, EveryKeyDelivered in
  (union System, { TestAll });

// One spec each over the full fault mix, for mutate.py.
test tcOnlyAtMostOnce [main = TestAll]:
  assert AtMostOnceStart in (union System, { TestAll });

// A repeated Run joins a live run only after a connection drop, so the traffic
// that exercises it is the drops alone.
test tcOnlyAtMostOnceJoin [main = TestPartition]:
  assert AtMostOnceStart in (union System, { TestPartition });

test tcOnlyNoStartAfterFence [main = TestRuntimeRestart]:
  assert NoStartAfterFence in (union System, { TestRuntimeRestart });

test tcOnlyUnknownIsFinal [main = TestAll]:
  assert UnknownIsFinal in (union System, { TestAll });

test tcOnlyOutcomeFaithful [main = TestAll]:
  assert OutcomeFaithful in (union System, { TestAll });

test tcOnlyStaleToken [main = TestAll]:
  assert StaleTokenRefused in (union System, { TestAll });

test tcOnlyCancelOnAbort [main = TestAll]:
  assert CancelOnlyOnAbort in (union System, { TestAll });

// Probes, one per situation the model must reach.
test tcProbeResendJoins [main = TestPartition]:
  assert ProbeResendJoinsLiveRun in (union System, { TestPartition });

test tcProbeStaleRun [main = TestOpenCrash]:
  assert ProbeStaleRunRefused in (union System, { TestOpenCrash });

test tcProbeFenceBeforeRun [main = TestRuntimeRestart]:
  assert ProbeFenceBeforeRun in (union System, { TestRuntimeRestart });

test tcProbeStoredOutcomeRead [main = TestPartition]:
  assert ProbeResendReadsStoredOutcome in (union System, { TestPartition });

test tcProbeRecoveryFenced [main = TestOpenCrash]:
  assert ProbeRecoveryFenced in (union System, { TestOpenCrash });

test tcProbeKeyUnknown [main = TestHostCrash]:
  assert ProbeKeyUnknown in (union System, { TestHostCrash });

test tcProbeAbortCancels [main = TestOpenCrash]:
  assert ProbeAbortCancels in (union System, { TestOpenCrash });

// A call the executor may have run is never answered as untouched, even when
// the executor restarted and holds no plane (README.md, "Defects found").
test tcDefectNoPlane [main = TestHostCrash]:
  assert RefusalMeansUntouched in (union System, { TestHostCrash });

test tcDefectLateRun [main = TestRuntimeRestartAckAtOnce]:
  assert AtMostOnceStart, NoStartAfterFence, UnknownIsFinal, OutcomeFaithful, StaleTokenRefused, CancelOnlyOnAbort, EveryKeyDelivered in
  (union System, { TestRuntimeRestartAckAtOnce });
