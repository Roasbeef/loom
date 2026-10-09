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

module System = { Wire, Host, Body, ExecBody, Orch, Call, Record, Exec, Chaos, Harness };

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
      new Harness((replays = mixed(), acks = ACK_AFTER_QUIET, breaks = 0, crashes = 0, opens = 0, restarts = 0, executions = 0, cancels = 0));
    }
  }
}

machine TestPartition {
  start state Init {
    entry {
      new Harness((replays = mixed(), acks = ACK_AFTER_QUIET, breaks = 3, crashes = 0, opens = 0, restarts = 0, executions = 0, cancels = 0));
    }
  }
}

machine TestOpenCrash {
  start state Init {
    entry {
      new Harness((replays = fenced(), acks = ACK_AFTER_QUIET, breaks = 1, crashes = 0, opens = 2, restarts = 0, executions = 0, cancels = 0));
    }
  }
}

machine TestHostCrash {
  start state Init {
    entry {
      new Harness((replays = mixed(), acks = ACK_AFTER_QUIET, breaks = 1, crashes = 1, opens = 1, restarts = 0, executions = 0, cancels = 0));
    }
  }
}

// Every fault: connection drops, an executor crash, an open ending and a
// runtime restart.
machine TestAll {
  start state Init {
    entry {
      new Harness((replays = fenced(), acks = ACK_AFTER_QUIET, breaks = 2, crashes = 1, opens = 1, restarts = 1, executions = 0, cancels = 0));
    }
  }
}

// A runtime restart inside one open, with the open's token unchanged.
machine TestRuntimeRestart {
  start state Init {
    entry {
      new Harness((replays = fenced(), acks = ACK_AFTER_QUIET, breaks = 0, crashes = 0, opens = 0, restarts = 2, executions = 0, cancels = 0));
    }
  }
}

// The same runtime restarts, with the acknowledgement sent as soon as the
// result is staged.
machine TestRuntimeRestartAckAtOnce {
  start state Init {
    entry {
      new Harness((replays = fenced(), acks = ACK_AT_ONCE, breaks = 0, crashes = 0, opens = 0, restarts = 2, executions = 0, cancels = 0));
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

// The same traffic with the acknowledgement sent at once, for the mutant that
// deletes an acknowledged key's row.
test tcOnlyNoStartAfterAck [main = TestRuntimeRestartAckAtOnce]:
  assert NoStartAfterFence in (union System, { TestRuntimeRestartAckAtOnce });

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

// --- background executions ----------------------------------------------------

// No tool calls: the open attaches only to carry the executions.
fun noCalls(): seq[tReplay] {
  var r: seq[tReplay];
  return r;
}

machine TestExecQuiet {
  start state Init {
    entry {
      new Harness((replays = noCalls(), acks = ACK_AFTER_QUIET, breaks = 0, crashes = 0, opens = 0, restarts = 0, executions = 2, cancels = 0));
    }
  }
}

// Cancels racing starts and finishes, over dropped connections.
machine TestExecCancel {
  start state Init {
    entry {
      new Harness((replays = noCalls(), acks = ACK_AFTER_QUIET, breaks = 2, crashes = 0, opens = 0, restarts = 0, executions = 2, cancels = 2));
    }
  }
}

// An orchestrator restart, with the workers' starts still in flight, and a
// dropped connection.
machine TestExecOpenCrash {
  start state Init {
    entry {
      new Harness((replays = noCalls(), acks = ACK_AFTER_QUIET, breaks = 1, crashes = 0, opens = 1, restarts = 0, executions = 2, cancels = 1));
    }
  }
}

// An executor restart under running programs.
machine TestExecHostCrash {
  start state Init {
    entry {
      new Harness((replays = noCalls(), acks = ACK_AFTER_QUIET, breaks = 1, crashes = 1, opens = 0, restarts = 0, executions = 2, cancels = 1));
    }
  }
}

// Executions beside tool calls, under every fault.
machine TestExecAll {
  start state Init {
    entry {
      new Harness((replays = mixed(), acks = ACK_AFTER_QUIET, breaks = 2, crashes = 1, opens = 1, restarts = 0, executions = 2, cancels = 2));
    }
  }
}

test tcExecQuiet [main = TestExecQuiet]:
  assert AtMostOnceStart, UnknownIsFinal, StaleTokenRefused, CancelOnlyOnAbort, ExecNoStartAfterStop, ExecFinishedIsStored, ExecStopOnlyOnDecision, ExecNotLostWhenFinished, ExecAckOnlyWhenRecordTerminal, EveryExecutionSettles in
  (union System, { TestExecQuiet });

test tcExecCancel [main = TestExecCancel]:
  assert AtMostOnceStart, UnknownIsFinal, StaleTokenRefused, CancelOnlyOnAbort, ExecNoStartAfterStop, ExecFinishedIsStored, ExecStopOnlyOnDecision, ExecNotLostWhenFinished, ExecAckOnlyWhenRecordTerminal, EveryExecutionSettles in
  (union System, { TestExecCancel });

test tcExecOpenCrash [main = TestExecOpenCrash]:
  assert AtMostOnceStart, UnknownIsFinal, StaleTokenRefused, CancelOnlyOnAbort, ExecNoStartAfterStop, ExecFinishedIsStored, ExecStopOnlyOnDecision, ExecNotLostWhenFinished, ExecAckOnlyWhenRecordTerminal, EveryExecutionSettles in
  (union System, { TestExecOpenCrash });

test tcExecHostCrash [main = TestExecHostCrash]:
  assert AtMostOnceStart, UnknownIsFinal, StaleTokenRefused, CancelOnlyOnAbort, ExecNoStartAfterStop, ExecFinishedIsStored, ExecStopOnlyOnDecision, ExecNotLostWhenFinished, ExecAckOnlyWhenRecordTerminal, EveryExecutionSettles in
  (union System, { TestExecHostCrash });

test tcExecAll [main = TestExecAll]:
  assert AtMostOnceStart, NoStartAfterFence, UnknownIsFinal, OutcomeFaithful, StaleTokenRefused, CancelOnlyOnAbort, EveryKeyDelivered, ExecNoStartAfterStop, ExecFinishedIsStored, ExecStopOnlyOnDecision, ExecNotLostWhenFinished, ExecAckOnlyWhenRecordTerminal, EveryExecutionSettles in
  (union System, { TestExecAll });

// One spec each, for mutate.py.
test tcOnlyExecNoStartAfterStop [main = TestExecCancel]:
  assert ExecNoStartAfterStop in (union System, { TestExecCancel });

test tcOnlyExecStopOnlyOnDecision [main = TestExecCancel]:
  assert ExecStopOnlyOnDecision in (union System, { TestExecCancel });

test tcOnlyExecAckOnlyWhenRecordTerminal [main = TestExecCancel]:
  assert ExecAckOnlyWhenRecordTerminal in (union System, { TestExecCancel });

test tcOnlyExecNotLostWhenFinished [main = TestExecCancel]:
  assert ExecNotLostWhenFinished in (union System, { TestExecCancel });

test tcOnlyExecAtMostOnce [main = TestExecHostCrash]:
  assert AtMostOnceStart in (union System, { TestExecHostCrash });

test tcOnlyEveryExecutionSettles [main = TestExecCancel]:
  assert EveryExecutionSettles in (union System, { TestExecCancel });

test tcProbeExecStartBarred [main = TestExecCancel]:
  assert ProbeExecStartBarred in (union System, { TestExecCancel });

test tcProbeExecRecoveredValue [main = TestExecOpenCrash]:
  assert ProbeExecRecoveredValue in (union System, { TestExecOpenCrash });
