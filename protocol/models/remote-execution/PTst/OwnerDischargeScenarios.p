// Finite scripts wait for actual owner/downstream replies between commands.
// Split reservation/start and final/drain turns expose the two crash windows.
machine OwnerDischargeScenario {
  var mode: tRunMode; var owner: machine; var downstream: machine; var stage: int;
  start state Init {
    entry (p: tRunMode) {
      mode = p; announce mScenarioBegin; announce mRunScenario, mode;
      downstream = new RunDownstream(this);
      owner = new RunCustodian((driver = this, downstream = downstream));
      if (mode == RunFreshFails) { send owner, eRunAdmit, (key = 1, commit = RunCommitFailed); }
      else { send owner, eRunAdmit, (key = 1, commit = RunCommitOk); }
      goto Driving;
    }
  }
  state Driving {
    on eRunView do (v: tRunView) { drive(v); }
    on eRunHeld do (origin: tRunOrigin) {
      assert mode == RunLost && stage == 2 && origin == (key = 1, incarnation = 1, ordinal = 1),
        "scenario did not receive its actual held downstream request";
      stage = 3; send owner, eRunFence, (pin = pin(1, 1), cause = RunWorkerLost);
    }
    on eRunReceiptStored do (origin: tRunOrigin) {
      assert mode == RunLost && stage == 8 && origin == (key = 1, incarnation = 1, ordinal = 1),
        "scenario did not receive its original exact late receipt";
      stage = 9; send downstream, eRunReadReceipt, origin;
    }
    on eRunReceiptRead do (origin: tRunOrigin) {
      assert mode == RunLost && stage == 9 && origin == (key = 1, incarnation = 1, ordinal = 1),
        "late receipt must remain available by original exact origin";
      finish();
    }
  }
  state Finished { }
  fun pin(id: int, boot: int): tRunPin { return (key = id, incarnation = boot); }
  fun finish() { announce mScenarioEnd; goto Finished; }
  fun drive(v: tRunView) {
    if (mode == RunHappy) {
      if (stage == 0) {
        assert v.answer == RunFresh, "unexpected owner reply at RunHappy 0";
        stage = 1; send owner, eRunStart, pin(1, 1); return;
      }
      if (stage == 1) {
        assert v.answer == RunStarted, "unexpected owner reply at RunHappy 1";
        stage = 2; send owner, eRunFinal, (pin = pin(1, 1), outcome = 1, commit = RunCommitOk); return;
      }
      if (stage == 2) {
        assert v.answer == RunFinalStored, "unexpected owner reply at RunHappy 2";
        stage = 3; send owner, eRunCollect, 1; return;
      }
      if (stage == 3) {
        assert v.answer == RunCollectionPending, "unexpected owner reply at RunHappy 3";
        stage = 4; send owner, eRunDrain, (pin = pin(1, 1), commit = RunCommitOk); return;
      }
      if (stage == 4) {
        assert v.answer == RunDrained, "unexpected owner reply at RunHappy 4";
        stage = 5; send owner, eRunCollect, 1; return;
      }
      if (stage == 5) {
        assert v.answer == RunCollected, "unexpected owner reply at RunHappy 5";
        stage = 6; send owner, eRunAdmit, (key = 2, commit = RunCommitOk); return;
      }
      if (stage == 6) {
        assert v.answer == RunFresh, "unexpected owner reply at RunHappy 6";
        stage = 7; send owner, eRunStart, pin(2, 1); return;
      }
      if (stage == 7) {
        assert v.answer == RunStarted, "unexpected owner reply at RunHappy 7";
        stage = 8; send owner, eRunFinal, (pin = pin(2, 1), outcome = 1, commit = RunCommitOk); return;
      }
      if (stage == 8) {
        assert v.answer == RunFinalStored, "unexpected owner reply at RunHappy 8";
        stage = 9; send owner, eRunDrain, (pin = pin(2, 1), commit = RunCommitOk); return;
      }
      if (stage == 9) {
        assert v.answer == RunDrained, "unexpected owner reply at RunHappy 9";
        stage = 10; send owner, eRunRestart; return;
      }
      if (stage == 10) {
        assert v.answer == RunRebooted, "unexpected owner reply at RunHappy 10";
        stage = 11; finish(); return;
      }
    }
    if (mode == RunCrashBefore) {
      if (stage == 0) {
        assert v.answer == RunFresh, "unexpected owner reply at RunCrashBefore 0";
        stage = 1; send owner, eRunRestart; return;
      }
      if (stage == 1) {
        assert v.answer == RunRebooted, "unexpected owner reply at RunCrashBefore 1";
        stage = 2; send owner, eRunAdmit, (key = 2, commit = RunCommitOk); return;
      }
      if (stage == 2) {
        assert v.answer == RunRefused, "unexpected owner reply at RunCrashBefore 2";
        stage = 3; send owner, eRunStart, pin(1, 1); return;
      }
      if (stage == 3) {
        assert v.answer == RunPinnedRejected, "unexpected owner reply at RunCrashBefore 3";
        stage = 4; finish(); return;
      }
    }
    if (mode == RunCrashAfter) {
      if (stage == 0) {
        assert v.answer == RunFresh, "unexpected owner reply at RunCrashAfter 0";
        stage = 1; send owner, eRunStart, pin(1, 1); return;
      }
      if (stage == 1) {
        assert v.answer == RunStarted, "unexpected owner reply at RunCrashAfter 1";
        stage = 2; send owner, eRunFinal, (pin = pin(1, 1), outcome = 1, commit = RunCommitOk); return;
      }
      if (stage == 2) {
        assert v.answer == RunFinalStored, "unexpected owner reply at RunCrashAfter 2";
        stage = 3; send owner, eRunRestart; return;
      }
      if (stage == 3) {
        assert v.answer == RunRebooted, "unexpected owner reply at RunCrashAfter 3";
        stage = 4; send owner, eRunRead, 1; return;
      }
      if (stage == 4) {
        assert v.answer == RunObserved, "unexpected owner reply at RunCrashAfter 4";
        stage = 5; send owner, eRunDrain, (pin = pin(1, 1), commit = RunCommitOk); return;
      }
      if (stage == 5) {
        assert v.answer == RunPinnedRejected, "unexpected owner reply at RunCrashAfter 5";
        stage = 6; send owner, eRunCollect, 1; return;
      }
      if (stage == 6) {
        assert v.answer == RunCollectionPending, "unexpected owner reply at RunCrashAfter 6";
        stage = 7; send owner, eRunAdmit, (key = 2, commit = RunCommitOk); return;
      }
      if (stage == 7) {
        assert v.answer == RunRefused, "unexpected owner reply at RunCrashAfter 7";
        stage = 8; finish(); return;
      }
    }
    if (mode == RunLost) {
      if (stage == 0) {
        assert v.answer == RunFresh, "unexpected owner reply at RunLost 0";
        stage = 1; send owner, eRunStart, pin(1, 1); return;
      }
      if (stage == 1) {
        assert v.answer == RunStarted, "unexpected owner reply at RunLost 1";
        stage = 2; send owner, eRunPinnedChild, (key = 1, incarnation = 1, ordinal = 1); return;
      }
      if (stage == 3) {
        assert v.answer == RunFenced, "unexpected owner reply at RunLost 3";
        stage = 4; send owner, eRunDrain, (pin = pin(1, 1), commit = RunCommitOk); return;
      }
      if (stage == 4) {
        assert v.answer == RunDrained, "unexpected owner reply at RunLost 4";
        stage = 5; send owner, eRunRestart; return;
      }
      if (stage == 5) {
        assert v.answer == RunRebooted, "unexpected owner reply at RunLost 5";
        stage = 6; send owner, eRunAdmit, (key = 2, commit = RunCommitOk); return;
      }
      if (stage == 6) {
        assert v.answer == RunRefused, "unexpected owner reply at RunLost 6";
        stage = 7; send owner, eRunPinnedChild, (key = 1, incarnation = 1, ordinal = 2); return;
      }
      if (stage == 7) {
        assert v.answer == RunPinnedRejected, "unexpected owner reply at RunLost 7";
        stage = 8; send downstream, eRunReceipt, (key = 1, incarnation = 1, ordinal = 1); return;
      }
    }
    if (mode == RunFatal) {
      if (stage == 0) {
        assert v.answer == RunFresh, "unexpected owner reply at RunFatal 0";
        stage = 1; send owner, eRunStart, pin(1, 1); return;
      }
      if (stage == 1) {
        assert v.answer == RunStarted, "unexpected owner reply at RunFatal 1";
        stage = 2; send owner, eRunFence, (pin = pin(1, 1), cause = RunConsumerFatal); return;
      }
      if (stage == 2) {
        assert v.answer == RunFenced, "unexpected owner reply at RunFatal 2";
        stage = 3; send owner, eRunFinal, (pin = pin(1, 1), outcome = 1, commit = RunCommitOk); return;
      }
      if (stage == 3) {
        assert v.answer == RunFinalStored, "unexpected owner reply at RunFatal 3";
        stage = 4; send owner, eRunDrain, (pin = pin(1, 1), commit = RunCommitOk); return;
      }
      if (stage == 4) {
        assert v.answer == RunDrained, "unexpected owner reply at RunFatal 4";
        stage = 5; send owner, eRunCollect, 1; return;
      }
      if (stage == 5) {
        assert v.answer == RunCollectionPending, "unexpected owner reply at RunFatal 5";
        stage = 6; send owner, eRunRestart; return;
      }
      if (stage == 6) {
        assert v.answer == RunRebooted, "unexpected owner reply at RunFatal 6";
        stage = 7; send owner, eRunAdmit, (key = 2, commit = RunCommitOk); return;
      }
      if (stage == 7) {
        assert v.answer == RunRefused, "unexpected owner reply at RunFatal 7";
        stage = 8; finish(); return;
      }
    }
    if (mode == RunFinalFails) {
      if (stage == 0) {
        assert v.answer == RunFresh, "unexpected owner reply at RunFinalFails 0";
        stage = 1; send owner, eRunStart, pin(1, 1); return;
      }
      if (stage == 1) {
        assert v.answer == RunStarted, "unexpected owner reply at RunFinalFails 1";
        stage = 2; send owner, eRunFinal, (pin = pin(1, 1), outcome = 1, commit = RunCommitFailed); return;
      }
      if (stage == 2) {
        assert v.answer == RunCommitRejected, "unexpected owner reply at RunFinalFails 2";
        stage = 3; send owner, eRunDrain, (pin = pin(1, 1), commit = RunCommitOk); return;
      }
      if (stage == 3) {
        assert v.answer == RunDrained, "unexpected owner reply at RunFinalFails 3";
        stage = 4; send owner, eRunRestart; return;
      }
      if (stage == 4) {
        assert v.answer == RunRebooted, "unexpected owner reply at RunFinalFails 4";
        stage = 5; send owner, eRunAdmit, (key = 2, commit = RunCommitOk); return;
      }
      if (stage == 5) {
        assert v.answer == RunRefused, "unexpected owner reply at RunFinalFails 5";
        stage = 6; finish(); return;
      }
    }
    if (mode == RunDischargeFails) {
      if (stage == 0) {
        assert v.answer == RunFresh, "unexpected owner reply at RunDischargeFails 0";
        stage = 1; send owner, eRunStart, pin(1, 1); return;
      }
      if (stage == 1) {
        assert v.answer == RunStarted, "unexpected owner reply at RunDischargeFails 1";
        stage = 2; send owner, eRunFinal, (pin = pin(1, 1), outcome = 1, commit = RunCommitOk); return;
      }
      if (stage == 2) {
        assert v.answer == RunFinalStored, "unexpected owner reply at RunDischargeFails 2";
        stage = 3; send owner, eRunDrain, (pin = pin(1, 1), commit = RunCommitFailed); return;
      }
      if (stage == 3) {
        assert v.answer == RunDrained, "unexpected owner reply at RunDischargeFails 3";
        stage = 4; send owner, eRunAdmit, (key = 2, commit = RunCommitOk); return;
      }
      if (stage == 4) {
        assert v.answer == RunRefused, "unexpected owner reply at RunDischargeFails 4";
        stage = 5; send owner, eRunDrain, (pin = pin(1, 1), commit = RunCommitOk); return;
      }
      if (stage == 5) {
        assert v.answer == RunDrained, "unexpected owner reply at RunDischargeFails 5";
        stage = 6; send owner, eRunRestart; return;
      }
      if (stage == 6) {
        assert v.answer == RunRebooted, "unexpected owner reply at RunDischargeFails 6";
        stage = 7; send owner, eRunAdmit, (key = 2, commit = RunCommitOk); return;
      }
      if (stage == 7) {
        assert v.answer == RunRefused, "unexpected owner reply at RunDischargeFails 7";
        stage = 8; finish(); return;
      }
    }
    if (mode == RunFreshFails) {
      if (stage == 0) {
        assert v.answer == RunCommitRejected, "unexpected owner reply at RunFreshFails 0";
        stage = 1; send owner, eRunAdmit, (key = 2, commit = RunCommitOk); return;
      }
      if (stage == 1) {
        assert v.answer == RunFresh, "unexpected owner reply at RunFreshFails 1";
        stage = 2; send owner, eRunStart, pin(2, 1); return;
      }
      if (stage == 2) {
        assert v.answer == RunStarted, "unexpected owner reply at RunFreshFails 2";
        stage = 3; send owner, eRunFinal, (pin = pin(2, 1), outcome = 1, commit = RunCommitOk); return;
      }
      if (stage == 3) {
        assert v.answer == RunFinalStored, "unexpected owner reply at RunFreshFails 3";
        stage = 4; send owner, eRunDrain, (pin = pin(2, 1), commit = RunCommitOk); return;
      }
      if (stage == 4) {
        assert v.answer == RunDrained, "unexpected owner reply at RunFreshFails 4";
        stage = 5; finish(); return;
      }
    }
    assert false, "unexpected owner reply outside finite script";
  }
}

module OwnerDischargeSystem = { RunCustodian, RunDownstream, OwnerDischargeScenario };
machine TestOwnerDischargeHappy { start state Init { entry { new OwnerDischargeScenario(RunHappy); } } }
test tcOwnerDischargeHappy [main = TestOwnerDischargeHappy]: assert OwnerDischargeSafety, DirectedProgress in (union OwnerDischargeSystem, { TestOwnerDischargeHappy });
test tcProbeOwnerDischargeHappy [main = TestOwnerDischargeHappy]: assert OwnerDischargeSafety, OwnerDischargeReachability in (union OwnerDischargeSystem, { TestOwnerDischargeHappy });
machine TestOwnerDischargeCrashBeforeStart { start state Init { entry { new OwnerDischargeScenario(RunCrashBefore); } } }
test tcOwnerDischargeCrashBeforeStart [main = TestOwnerDischargeCrashBeforeStart]: assert OwnerDischargeSafety, DirectedProgress in (union OwnerDischargeSystem, { TestOwnerDischargeCrashBeforeStart });
test tcProbeOwnerDischargeCrashBeforeStart [main = TestOwnerDischargeCrashBeforeStart]: assert OwnerDischargeSafety, OwnerDischargeReachability in (union OwnerDischargeSystem, { TestOwnerDischargeCrashBeforeStart });
machine TestOwnerDischargeCrashAfterFinal { start state Init { entry { new OwnerDischargeScenario(RunCrashAfter); } } }
test tcOwnerDischargeCrashAfterFinal [main = TestOwnerDischargeCrashAfterFinal]: assert OwnerDischargeSafety, DirectedProgress in (union OwnerDischargeSystem, { TestOwnerDischargeCrashAfterFinal });
test tcProbeOwnerDischargeCrashAfterFinal [main = TestOwnerDischargeCrashAfterFinal]: assert OwnerDischargeSafety, OwnerDischargeReachability in (union OwnerDischargeSystem, { TestOwnerDischargeCrashAfterFinal });
machine TestOwnerDischargeWorkerLost { start state Init { entry { new OwnerDischargeScenario(RunLost); } } }
test tcOwnerDischargeWorkerLost [main = TestOwnerDischargeWorkerLost]: assert OwnerDischargeSafety, DirectedProgress in (union OwnerDischargeSystem, { TestOwnerDischargeWorkerLost });
test tcProbeOwnerDischargeWorkerLost [main = TestOwnerDischargeWorkerLost]: assert OwnerDischargeSafety, OwnerDischargeReachability in (union OwnerDischargeSystem, { TestOwnerDischargeWorkerLost });
machine TestOwnerDischargeFatalSticky { start state Init { entry { new OwnerDischargeScenario(RunFatal); } } }
test tcOwnerDischargeFatalSticky [main = TestOwnerDischargeFatalSticky]: assert OwnerDischargeSafety, DirectedProgress in (union OwnerDischargeSystem, { TestOwnerDischargeFatalSticky });
test tcProbeOwnerDischargeFatalSticky [main = TestOwnerDischargeFatalSticky]: assert OwnerDischargeSafety, OwnerDischargeReachability in (union OwnerDischargeSystem, { TestOwnerDischargeFatalSticky });
machine TestOwnerDischargeFinalCommitFailed { start state Init { entry { new OwnerDischargeScenario(RunFinalFails); } } }
test tcOwnerDischargeFinalCommitFailed [main = TestOwnerDischargeFinalCommitFailed]: assert OwnerDischargeSafety, DirectedProgress in (union OwnerDischargeSystem, { TestOwnerDischargeFinalCommitFailed });
test tcProbeOwnerDischargeFinalCommitFailed [main = TestOwnerDischargeFinalCommitFailed]: assert OwnerDischargeSafety, OwnerDischargeReachability in (union OwnerDischargeSystem, { TestOwnerDischargeFinalCommitFailed });
machine TestOwnerDischargeDischargeCommitFailed { start state Init { entry { new OwnerDischargeScenario(RunDischargeFails); } } }
test tcOwnerDischargeDischargeCommitFailed [main = TestOwnerDischargeDischargeCommitFailed]: assert OwnerDischargeSafety, DirectedProgress in (union OwnerDischargeSystem, { TestOwnerDischargeDischargeCommitFailed });
test tcProbeOwnerDischargeDischargeCommitFailed [main = TestOwnerDischargeDischargeCommitFailed]: assert OwnerDischargeSafety, OwnerDischargeReachability in (union OwnerDischargeSystem, { TestOwnerDischargeDischargeCommitFailed });
machine TestOwnerDischargeFreshCommitFailed { start state Init { entry { new OwnerDischargeScenario(RunFreshFails); } } }
test tcOwnerDischargeFreshCommitFailed [main = TestOwnerDischargeFreshCommitFailed]: assert OwnerDischargeSafety, DirectedProgress in (union OwnerDischargeSystem, { TestOwnerDischargeFreshCommitFailed });
test tcProbeOwnerDischargeFreshCommitFailed [main = TestOwnerDischargeFreshCommitFailed]: assert OwnerDischargeSafety, OwnerDischargeReachability in (union OwnerDischargeSystem, { TestOwnerDischargeFreshCommitFailed });
