// The fault mixes and the test cases over them.
//
// A mix names what it spends, in the order of `planOf`: the two connections
// (`breaks1` between the owner and the receiving orchestrator, `breaks2` between
// the receiving orchestrator and the executor), restarts of the receiving
// orchestrator, the executor and the owner, reads of the session's record that
// fail, a store with no room, a capture that arrives short, askers that give up,
// the child's work, and a bundle that is late.

fun planOf(place: tPlace, breaks1: int, breaks2: int, crashOrch: int, crashExec: int, crashOwner: int, unreadable: int, noRoom: int, partial: int, giveUps: int, works: int, holdLate: bool, storeFull: int, runEnds: int, pairFull: bool, agencyFails: int): tPlan {
  return (place = place, shared = false, badState = false, refuseApply = false, holdLate = holdLate, breaks1 = breaks1, breaks2 = breaks2, crashOrch = crashOrch, crashExec = crashExec, crashOwner = crashOwner, unreadable = unreadable, noRoom = noRoom, partial = partial, giveUps = giveUps, works = works, storeFull = storeFull, runEnds = runEnds, pairFull = pairFull, agencyFails = agencyFails);
}

fun shared(p: tPlan): tPlan {
  var q: tPlan;
  q = p;
  q.shared = true;
  return q;
}

fun badState(p: tPlan): tPlan {
  var q: tPlan;
  q = p;
  q.badState = true;
  return q;
}

fun refusedApply(p: tPlan): tPlan {
  var q: tPlan;
  q = p;
  q.refuseApply = true;
  return q;
}

machine TestQuietExec {
  start state Init {
    entry {
      new Harness(planOf(PL_EXEC, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, false, 0, 0, false, 0));
    }
  }
}

machine TestQuietDir {
  start state Init {
    entry {
      new Harness(planOf(PL_DIR, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, false, 0, 0, false, 0));
    }
  }
}

// Connections dropped in the middle of the landing and of the join.
machine TestDrops {
  start state Init {
    entry {
      new Harness(planOf(PL_EXEC, 2, 2, 0, 0, 1, 0, 0, 0, 1, 1, false, 0, 0, false, 0));
    }
  }
}

// The receiving orchestrator restarts, twice, so a pass is cut off and a landed
// child's run ends.
machine TestOrchRestart {
  start state Init {
    entry {
      new Harness(planOf(PL_EXEC, 0, 0, 2, 0, 0, 0, 0, 0, 1, 1, false, 0, 0, false, 0));
    }
  }
}

// The executor restarts, twice, so the fence the orchestrator holds goes stale.
machine TestExecRestart {
  start state Init {
    entry {
      new Harness(planOf(PL_EXEC, 0, 0, 0, 2, 0, 0, 0, 1, 0, 1, false, 0, 0, false, 0));
    }
  }
}

// Transient failures: a store with no room, a record that cannot be read, a
// capture that arrives short, and a bundle that is late.
machine TestTransient {
  start state Init {
    entry {
      new Harness(planOf(PL_EXEC, 0, 0, 0, 0, 0, 2, 2, 1, 1, 1, true, 0, 0, false, 0));
    }
  }
}

// Every fault together.
// A child that began and worked, whose spawn is asked for again after the
// orchestrator restarted: the retried land must not send the seed over the work.
machine TestRetryAfterWork {
  start state Init {
    entry {
      new Harness(planOf(PL_EXEC, 2, 0, 1, 0, 0, 0, 0, 0, 2, 0, false, 0, 0, false, 0));
    }
  }
}

// The child's commits come back across a lost reply, a resend, an executor that
// restarted, a store with no room and a join asked again.
machine TestReturn {
  start state Init {
    entry {
      new Harness(planOf(PL_EXEC, 2, 0, 1, 1, 0, 0, 0, 0, 1, 1, false, 2, 0, false, 0));
    }
  }
}

// The run ends while the spawner is at its cap.
machine TestRunEnd {
  start state Init {
    entry {
      new Harness(planOf(PL_EXEC, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, false, 0, 2, true, 0));
    }
  }
}

// The link to the executor breaks while a checkout is running, so the request that
// follows the repair arrives at an executor that is still applying.
machine TestApplyOverlap {
  start state Init {
    entry {
      new Harness(planOf(PL_EXEC, 0, 4, 0, 0, 0, 0, 0, 0, 0, 1, false, 0, 0, false, 0));
    }
  }
}

// A resend whose child began, whose answer the Agency fails to give.
machine TestAgencyFails {
  start state Init {
    entry {
      new Harness(planOf(PL_EXEC, 2, 0, 0, 0, 0, 0, 0, 0, 2, 0, false, 0, 0, false, 3));
    }
  }
}

machine TestAllExec {
  start state Init {
    entry {
      new Harness(planOf(PL_EXEC, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, true, 1, 1, false, 0));
    }
  }
}

machine TestAllDir {
  start state Init {
    entry {
      new Harness(planOf(PL_DIR, 1, 0, 2, 0, 1, 1, 0, 0, 1, 1, true, 0, 0, false, 0));
    }
  }
}

// A census that says the workspace takes no state.
machine TestShared {
  start state Init {
    entry {
      new Harness(shared(planOf(PL_EXEC, 1, 1, 1, 1, 0, 0, 0, 0, 1, 0, false, 0, 0, false, 0)));
    }
  }
}

// A state the executor judges malformed, and one the workspace refuses.
machine TestBadState {
  start state Init {
    entry {
      new Harness(badState(planOf(PL_EXEC, 1, 1, 1, 0, 0, 0, 0, 0, 1, 0, false, 0, 0, false, 0)));
    }
  }
}

machine TestRefusedApply {
  start state Init {
    entry {
      new Harness(refusedApply(planOf(PL_EXEC, 1, 1, 1, 1, 0, 0, 0, 0, 1, 0, false, 0, 0, false, 0)));
    }
  }
}

machine TestBadDir {
  start state Init {
    entry {
      new Harness(badState(planOf(PL_DIR, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, false, 0, 0, false, 0)));
    }
  }
}

test tcReturn [main = TestReturn]:
  assert FirstTurnAfterSeed, AtMostOneSession, AppliedAtMostOnce, NoOlderOverNewer, RefNamesOnlyDescribedCommits, EverySpawnEnds, EverySettledChildIsReleased, JoinIsRepeatable, OneRefPerChild, EveryFinishedWorkIsReturned, NoReleaseWhileRunning, ResultKeptBeforeRelease, OneApplyAtATime in
  (union System, { TestReturn });

test tcRunEnd [main = TestRunEnd]:
  assert FirstTurnAfterSeed, AtMostOneSession, EverySpawnEnds, EverySettledChildIsReleased, JoinIsRepeatable, EveryFinishedWorkIsReturned, NoReleaseWhileRunning, RunEndStopsTheChildren in
  (union System, { TestRunEnd });

test tcQuietExec [main = TestQuietExec]:
  assert FirstTurnAfterSeed, AtMostOneSession, AppliedAtMostOnce, NoOlderOverNewer, RefNamesOnlyDescribedCommits, NoPermanentVerdictFromTransient, UnreadableIsNotBegun, EverySpawnEnds, EverySettledChildIsReleased, JoinIsRepeatable, OneRefPerChild, EveryFinishedWorkIsReturned, NoReleaseWhileRunning, ResultKeptBeforeRelease, OneApplyAtATime, RunEndStopsTheChildren, GivesUpOnlyAfterTheWindow in
  (union System, { TestQuietExec });

test tcQuietDir [main = TestQuietDir]:
  assert FirstTurnAfterSeed, AtMostOneSession, AppliedAtMostOnce, NoOlderOverNewer, RefNamesOnlyDescribedCommits, NoPermanentVerdictFromTransient, UnreadableIsNotBegun, EverySpawnEnds, EverySettledChildIsReleased, JoinIsRepeatable, OneRefPerChild, EveryFinishedWorkIsReturned, NoReleaseWhileRunning, ResultKeptBeforeRelease, OneApplyAtATime, RunEndStopsTheChildren, GivesUpOnlyAfterTheWindow in
  (union System, { TestQuietDir });

test tcDrops [main = TestDrops]:
  assert FirstTurnAfterSeed, AtMostOneSession, AppliedAtMostOnce, NoOlderOverNewer, RefNamesOnlyDescribedCommits, NoPermanentVerdictFromTransient, UnreadableIsNotBegun, EverySpawnEnds, EverySettledChildIsReleased, JoinIsRepeatable, OneRefPerChild, EveryFinishedWorkIsReturned, NoReleaseWhileRunning, ResultKeptBeforeRelease, OneApplyAtATime, RunEndStopsTheChildren, GivesUpOnlyAfterTheWindow in
  (union System, { TestDrops });

test tcOrchRestart [main = TestOrchRestart]:
  assert FirstTurnAfterSeed, AtMostOneSession, AppliedAtMostOnce, NoOlderOverNewer, RefNamesOnlyDescribedCommits, NoPermanentVerdictFromTransient, UnreadableIsNotBegun, EverySpawnEnds, EverySettledChildIsReleased, JoinIsRepeatable, OneRefPerChild, EveryFinishedWorkIsReturned, NoReleaseWhileRunning, ResultKeptBeforeRelease, OneApplyAtATime, RunEndStopsTheChildren, GivesUpOnlyAfterTheWindow in
  (union System, { TestOrchRestart });

test tcExecRestart [main = TestExecRestart]:
  assert FirstTurnAfterSeed, AtMostOneSession, AppliedAtMostOnce, NoOlderOverNewer, RefNamesOnlyDescribedCommits, NoPermanentVerdictFromTransient, UnreadableIsNotBegun, EverySpawnEnds, EverySettledChildIsReleased, JoinIsRepeatable, OneRefPerChild, EveryFinishedWorkIsReturned, NoReleaseWhileRunning, ResultKeptBeforeRelease, OneApplyAtATime, RunEndStopsTheChildren, GivesUpOnlyAfterTheWindow in
  (union System, { TestExecRestart });

test tcTransient [main = TestTransient]:
  assert FirstTurnAfterSeed, AtMostOneSession, AppliedAtMostOnce, NoOlderOverNewer, RefNamesOnlyDescribedCommits, NoPermanentVerdictFromTransient, UnreadableIsNotBegun, EverySpawnEnds, EverySettledChildIsReleased, JoinIsRepeatable, OneRefPerChild, EveryFinishedWorkIsReturned, NoReleaseWhileRunning, ResultKeptBeforeRelease, OneApplyAtATime, RunEndStopsTheChildren, GivesUpOnlyAfterTheWindow in
  (union System, { TestTransient });

test tcAllExec [main = TestAllExec]:
  assert FirstTurnAfterSeed, AtMostOneSession, AppliedAtMostOnce, NoOlderOverNewer, RefNamesOnlyDescribedCommits, NoPermanentVerdictFromTransient, UnreadableIsNotBegun, EverySpawnEnds, EverySettledChildIsReleased, JoinIsRepeatable, OneRefPerChild, EveryFinishedWorkIsReturned, NoReleaseWhileRunning, ResultKeptBeforeRelease, OneApplyAtATime, RunEndStopsTheChildren, GivesUpOnlyAfterTheWindow in
  (union System, { TestAllExec });

test tcAllDir [main = TestAllDir]:
  assert FirstTurnAfterSeed, AtMostOneSession, AppliedAtMostOnce, NoOlderOverNewer, RefNamesOnlyDescribedCommits, NoPermanentVerdictFromTransient, UnreadableIsNotBegun, EverySpawnEnds, EverySettledChildIsReleased, JoinIsRepeatable, OneRefPerChild, EveryFinishedWorkIsReturned, NoReleaseWhileRunning, ResultKeptBeforeRelease, OneApplyAtATime, RunEndStopsTheChildren, GivesUpOnlyAfterTheWindow in
  (union System, { TestAllDir });

test tcShared [main = TestShared]:
  assert FirstTurnAfterSeed, AtMostOneSession, NoPermanentVerdictFromTransient, EverySpawnEnds, EverySettledChildIsReleased in
  (union System, { TestShared });

test tcBadState [main = TestBadState]:
  assert FirstTurnAfterSeed, AtMostOneSession, NoPermanentVerdictFromTransient, EverySpawnEnds, EverySettledChildIsReleased in
  (union System, { TestBadState });

test tcRefusedApply [main = TestRefusedApply]:
  assert FirstTurnAfterSeed, AtMostOneSession, NoPermanentVerdictFromTransient, EverySpawnEnds, EverySettledChildIsReleased in
  (union System, { TestRefusedApply });

test tcBadDir [main = TestBadDir]:
  assert FirstTurnAfterSeed, NoPermanentVerdictFromTransient, EverySpawnEnds in
  (union System, { TestBadDir });

test tcOnlyFirstTurn [main = TestAllExec]:
  assert FirstTurnAfterSeed in (union System, { TestAllExec });

test tcOnlyOneSession [main = TestAllExec]:
  assert AtMostOneSession in (union System, { TestAllExec });

test tcRetryAfterWork [main = TestRetryAfterWork]:
  assert FirstTurnAfterSeed, AtMostOneSession, AppliedAtMostOnce, NoOlderOverNewer, NoPermanentVerdictFromTransient, UnreadableIsNotBegun, EverySpawnEnds, EverySettledChildIsReleased, JoinIsRepeatable, NoReleaseWhileRunning, ResultKeptBeforeRelease, OneApplyAtATime in
  (union System, { TestRetryAfterWork });

test tcOnlyAppliedOnce [main = TestAllExec]:
  assert AppliedAtMostOnce, NoOlderOverNewer in (union System, { TestAllExec });

test tcOnlyNoOlderOverNewer [main = TestApplyOverlap]:
  assert NoOlderOverNewer in (union System, { TestApplyOverlap });

test tcOnlyRefDescribed [main = TestTransient]:
  assert RefNamesOnlyDescribedCommits in (union System, { TestTransient });

test tcOnlyVerdict [main = TestTransient]:
  assert NoPermanentVerdictFromTransient in (union System, { TestTransient });

test tcOnlyVerdictRestart [main = TestExecRestart]:
  assert NoPermanentVerdictFromTransient in (union System, { TestExecRestart });

test tcOnlyReleasedRefused [main = TestBadState]:
  assert EverySettledChildIsReleased in (union System, { TestBadState });

test tcOnlyUnreadable [main = TestTransient]:
  assert UnreadableIsNotBegun in (union System, { TestTransient });

test tcOnlyBegunResend [main = TestAgencyFails]:
  assert NoReleaseWhileRunning in (union System, { TestAgencyFails });

test tcOnlyWindow [main = TestReturn]:
  assert GivesUpOnlyAfterTheWindow in (union System, { TestReturn });

test tcOnlyJoinRepeat [main = TestReturn]:
  assert JoinIsRepeatable in (union System, { TestReturn });

test tcOnlyReturnOnce [main = TestReturn]:
  assert OneRefPerChild, EveryFinishedWorkIsReturned in (union System, { TestReturn });

test tcOnlyNoEarlyRelease [main = TestReturn]:
  assert NoReleaseWhileRunning, ResultKeptBeforeRelease in (union System, { TestReturn });

test tcOnlyOneApply [main = TestApplyOverlap]:
  assert OneApplyAtATime in (union System, { TestApplyOverlap });

test tcOnlyRunEnd [main = TestRunEnd]:
  assert RunEndStopsTheChildren in (union System, { TestRunEnd });

test tcOnlySpawnEnds [main = TestTransient]:
  assert EverySpawnEnds in (union System, { TestTransient });

test tcOnlyReleased [main = TestQuietExec]:
  assert EverySettledChildIsReleased in (union System, { TestQuietExec });

test tcProbeApplyRetried [main = TestAllExec]:
  assert ProbeApplyRetried in (union System, { TestAllExec });

test tcProbeRestartBetweenApplyAndSpawn [main = TestAllExec]:
  assert ProbeRestartBetweenApplyAndSpawn in (union System, { TestAllExec });

test tcProbeReturnAfterExecRestart [main = TestExecRestart]:
  assert ProbeReturnAfterExecRestart in (union System, { TestExecRestart });

test tcProbeStaleFence [main = TestExecRestart]:
  assert ProbeStaleFence in (union System, { TestExecRestart });

test tcProbeVerdict [main = TestBadState]:
  assert ProbeVerdict in (union System, { TestBadState });

test tcProbeRef [main = TestQuietExec]:
  assert ProbeRef in (union System, { TestQuietExec });

test tcProbeNoRoom [main = TestTransient]:
  assert ProbeNoRoom in (union System, { TestTransient });

test tcProbeUnreadable [main = TestTransient]:
  assert ProbeUnreadable in (union System, { TestTransient });

test tcProbeJoinRepeated [main = TestReturn]:
  assert ProbeJoinRepeated in (union System, { TestReturn });

test tcProbeApplyJoined [main = TestApplyOverlap]:
  assert ProbeApplyJoined in (union System, { TestApplyOverlap });

test tcProbeStoreFull [main = TestReturn]:
  assert ProbeStoreFull in (union System, { TestReturn });

test tcProbeRunEndStopped [main = TestRunEnd]:
  assert ProbeRunEndStopped in (union System, { TestRunEnd });

test tcProbeAgencyFailed [main = TestAgencyFails]:
  assert ProbeAgencyFailed in (union System, { TestAgencyFails });

test tcProbeGaveUp [main = TestReturn]:
  assert ProbeGaveUp in (union System, { TestReturn });
