// Every step waits for a concrete endpoint reply. A delayed handoff may arrive
// after drain; no cross-sender signal-delivery ordering is assumed.
type tCreditStep = (command: tCreditCommand, outcome: tCreditOutcome,
  dataSlots: int, control: int, expectedRun: int, drain: tCreditDrainState);
machine BeamCreditScenario {
  var mode: tCreditMode; var endpoint: machine;
  var steps: seq[tCreditStep]; var index: int;
  start state Init {
    entry (p: tCreditMode) {
      mode = p; announce mScenarioBegin;
      endpoint = new BeamCredits(this); script();
      send endpoint, eCreditCommand, steps[0].command; goto Driving;
    }
  }
  state Driving {
    on eCreditView do (v: tCreditView) {
      assert v.outcome == steps[index].outcome && v.dataSlots == steps[index].dataSlots &&
        v.control == steps[index].control && v.run == steps[index].expectedRun && v.drain == steps[index].drain,
        "credit scenario did not reach its exact custody and capacity witness";
      index = index + 1;
      if (index == sizeof(steps)) {
        announce mCreditEnd, mode; announce mScenarioEnd; goto Finished;
      }
      send endpoint, eCreditCommand, steps[index].command;
    }
  }
  state Finished { }

  fun add(action: tCreditAction, slot: int, run: int, scope: int,
    lane: tCreditLane, outcome: tCreditOutcome, dataSlots: int, control: int, expectedRun: int) {
    steps += (sizeof(steps), (command = (action = action, slot = slot, run = run, scope = scope, lane = lane),
      outcome = outcome, dataSlots = dataSlots, control = control, expectedRun = expectedRun, drain = CreditBusy));
  }

  fun act(action: tCreditAction, slot: int, run: int, dataSlots: int, control: int, expectedRun: int) {
    add(action, slot, run, 1, CreditData, CreditStepped, dataSlots, control, expectedRun);
  }

  fun script() {
    var i: int;
    if (mode == CreditScopeFence || mode == CreditScopePending || mode == CreditScopeLost || mode == CreditScopeStale || mode == CreditScopeIdle || mode == CreditScopeOwner) {
      scopeScript(); return;
    }
    if (mode == CreditShared) {
      while (i < 4) {
        add(CreditReserve, 0, 0, 1 + i % 2, CreditData, CreditGranted, 3 - i, 2, i + 1);
        i = i + 1;
      }
      add(CreditReserve, 0, 0, 2, CreditData, CreditRefused, 0, 2, 0);
      add(CreditReserve, 0, 0, 1, CreditControl, CreditGranted, 0, 1, 5);
      add(CreditReserve, 0, 0, 2, CreditControl, CreditGranted, 0, 0, 6);
      add(CreditReserve, 0, 0, 1, CreditControl, CreditRefused, 0, 0, 0);
      act(CreditQuiesce, 0, 0, 0, 0, 0);
      i = 0;
      while (i < 4) { act(CreditDrain, i, i + 1, i + 1, 0, 0); i = i + 1; }
      act(CreditDrain, 4, 5, 4, 1, 0);
      act(CreditDrain, 5, 6, 4, 2, 0);
      add(CreditReserve, 0, 0, 1, CreditData, CreditRefused, 4, 2, 0);
      return;
    }
    add(CreditReserve, 0, 0, 1, CreditData, CreditGranted, 3, 2, 1);
    if (mode == CreditStale) {
      act(CreditDrain, 0, 1, 4, 2, 0);
      act(CreditHandoff, 0, 1, 4, 2, 0);
      add(CreditReserve, 0, 0, 2, CreditData, CreditGranted, 3, 2, 2);
      act(CreditHandoff, 0, 1, 3, 2, 2);
      act(CreditHandoff, 0, 2, 3, 2, 2);

      // Independent producers can deliver answer and drain in either order.
      if ($) {
        act(CreditDrain, 0, 2, 3, 2, 2); act(CreditAnswer, 0, 2, 4, 2, 0);
      } else {
        act(CreditAnswer, 0, 2, 3, 2, 2); act(CreditDrain, 0, 2, 4, 2, 0);
      }
      return;
    }
    act(CreditHandoff, 0, 1, 3, 2, 1);
    if (mode == CreditPending) {
      act(CreditConsumerGone, 0, 1, 3, 2, 1);
      act(CreditDrain, 0, 1, 3, 2, 1);
      add(CreditReserve, 0, 0, 2, CreditData, CreditGranted, 2, 2, 2);
      act(CreditAnswer, 0, 1, 3, 2, 0);
      act(CreditDrain, 1, 2, 4, 2, 0);
      return;
    }
    act(CreditRunLost, 0, 1, 3, 2, 1);
    act(CreditAnswer, 0, 1, 3, 2, 1);
    act(CreditDrain, 0, 1, 3, 2, 1);
    add(CreditReserve, 0, 0, 2, CreditData, CreditGranted, 2, 2, 2);
    act(CreditDrain, 1, 2, 3, 2, 0);
  }

  fun inspectScope(scope: int, drain: tCreditDrainState, dataSlots: int, control: int) {
    add(CreditSnapshot, 0, 0, scope, CreditData, CreditStepped, dataSlots, control, 0);
    steps[sizeof(steps) - 1].drain = drain;
  }

  fun fenceScope(scope: int, dataSlots: int, control: int) {
    add(CreditFenceScope, 0, 0, scope, CreditData, CreditStepped, dataSlots, control, 0);
  }

  fun scopeScript() {
    add(CreditReserve, 0, 0, 1, CreditData, CreditGranted, 3, 2, 1);
    if (mode == CreditScopeIdle) {
      act(CreditDrain, 0, 1, 4, 2, 0); fenceScope(1, 4, 2);
      inspectScope(1, CreditDrained, 4, 2);
      act(CreditCreditDown, 0, 0, 3, 2, 0);
      inspectScope(1, CreditDrained, 3, 2); fenceScope(3, 3, 2);
      inspectScope(3, CreditDrained, 3, 2);
      add(CreditReserve, 0, 0, 2, CreditData, CreditGranted, 2, 2, 2);
      act(CreditHandoff, 1, 2, 2, 2, 2); fenceScope(2, 2, 2);
      act(CreditCreditDown, 1, 2, 2, 2, 2); inspectScope(2, CreditUncertain, 2, 2);
      act(CreditAnswer, 1, 2, 2, 2, 2); act(CreditDrain, 1, 2, 2, 2, 2);
      inspectScope(2, CreditUncertain, 2, 2);
      add(CreditReserve, 0, 0, 4, CreditData, CreditGranted, 1, 2, 3);
      act(CreditDrain, 2, 3, 2, 2, 0); inspectScope(1, CreditDrained, 2, 2); return;
    }
    if (mode == CreditScopeOwner) {
      act(CreditDrain, 0, 1, 4, 2, 0);
      add(CreditOwnerDown, 0, 0, 1, CreditData, CreditStepped, 4, 2, 0);
      inspectScope(1, CreditDrained, 4, 2);
      add(CreditReserve, 0, 0, 1, CreditData, CreditRefused, 4, 2, 0);

      // This reservation can win before the busy owner's queued DOWN is applied.
      add(CreditReserve, 0, 0, 2, CreditData, CreditGranted, 3, 2, 2);
      add(CreditOwnerDown, 0, 0, 2, CreditData, CreditStepped, 3, 2, 0);
      inspectScope(2, CreditBusy, 3, 2);
      add(CreditReserve, 0, 0, 2, CreditData, CreditRefused, 3, 2, 0);
      act(CreditCreditDown, 0, 2, 3, 2, 2); inspectScope(2, CreditUncertain, 3, 2);
      add(CreditReserve, 0, 0, 3, CreditControl, CreditGranted, 3, 1, 3);
      act(CreditDrain, 4, 3, 3, 2, 0);
      inspectScope(1, CreditDrained, 3, 2); inspectScope(2, CreditUncertain, 3, 2); return;
    }
    if (mode == CreditScopeFence) {
      fenceScope(1, 3, 2); inspectScope(1, CreditBusy, 3, 2);
      add(CreditReserve, 0, 0, 1, CreditData, CreditRefused, 3, 2, 0);
      add(CreditReserve, 0, 0, 2, CreditData, CreditGranted, 2, 2, 2);
      act(CreditDrain, 0, 1, 3, 2, 0); inspectScope(1, CreditDrained, 3, 2);
      act(CreditHandoff, 0, 1, 3, 2, 0);
      add(CreditReserve, 0, 0, 1, CreditControl, CreditRefused, 3, 2, 0);
      add(CreditReserve, 0, 0, 2, CreditData, CreditGranted, 2, 2, 3);
      act(CreditHandoff, 0, 1, 2, 2, 3);
      act(CreditDrain, 0, 3, 3, 2, 0); act(CreditDrain, 1, 2, 4, 2, 0);
      inspectScope(1, CreditDrained, 4, 2); fenceScope(1, 4, 2);
      add(CreditReserve, 0, 0, 17, CreditControl, CreditRefused, 4, 2, 0);
      add(CreditReserve, 0, 0, 16, CreditControl, CreditGranted, 4, 1, 4);
      act(CreditDrain, 4, 4, 4, 2, 0); return;
    }
    act(CreditHandoff, 0, 1, 3, 2, 1);
    if (mode == CreditScopeStale) {
      act(CreditAnswer, 0, 1, 3, 2, 1); act(CreditDrain, 0, 1, 4, 2, 0);
      fenceScope(1, 4, 2); inspectScope(1, CreditDrained, 4, 2);
      add(CreditReserve, 0, 0, 2, CreditData, CreditGranted, 3, 2, 2);
      act(CreditHandoff, 0, 2, 3, 2, 2); fenceScope(2, 3, 2);
      act(CreditDrain, 0, 1, 3, 2, 2); inspectScope(2, CreditBusy, 3, 2);
      act(CreditAnswer, 0, 1, 3, 2, 2); inspectScope(2, CreditBusy, 3, 2);
      act(CreditAnswer, 0, 2, 3, 2, 2); inspectScope(2, CreditBusy, 3, 2);
      act(CreditDrain, 0, 2, 4, 2, 0); inspectScope(2, CreditDrained, 4, 2); return;
    }
    fenceScope(1, 3, 2);
    if (mode == CreditScopePending) {
      act(CreditConsumerGone, 0, 1, 3, 2, 1);
      // Both legal answer/drain orders leave the intermediate snapshot busy.
      if ($) {
        act(CreditDrain, 0, 1, 3, 2, 1); inspectScope(1, CreditBusy, 3, 2);
        act(CreditAnswer, 0, 1, 4, 2, 0);
      } else {
        act(CreditAnswer, 0, 1, 3, 2, 1); inspectScope(1, CreditBusy, 3, 2);
        act(CreditDrain, 0, 1, 4, 2, 0);
      }
      add(CreditReserve, 0, 0, 2, CreditControl, CreditGranted, 4, 1, 2);
      inspectScope(1, CreditDrained, 4, 1);
      act(CreditDrain, 4, 2, 4, 2, 0); return;
    }
    act(CreditServiceDown, 0, 1, 3, 2, 1); inspectScope(1, CreditUncertain, 3, 2);
    act(CreditAnswer, 0, 1, 3, 2, 1); act(CreditDrain, 0, 1, 3, 2, 1);
    inspectScope(1, CreditUncertain, 3, 2);
    add(CreditReserve, 0, 0, 1, CreditData, CreditRefused, 3, 2, 0);
    add(CreditReserve, 0, 0, 2, CreditData, CreditGranted, 2, 2, 2);
    act(CreditDrain, 1, 2, 3, 2, 0); fenceScope(2, 3, 2);
    inspectScope(2, CreditDrained, 3, 2); inspectScope(1, CreditUncertain, 3, 2);
  }

}

module BeamCreditSystem = { BeamCredits, BeamCreditScenario };
machine TestBeamCreditStale { start state Init { entry { new BeamCreditScenario(CreditStale); } } }
test tcBeamCreditStale [main = TestBeamCreditStale]: assert BeamCreditSafety, DirectedProgress in (union BeamCreditSystem, { TestBeamCreditStale });
test tcProbeBeamCreditStale [main = TestBeamCreditStale]: assert BeamCreditSafety, BeamCreditReachability, DirectedProgress in (union BeamCreditSystem, { TestBeamCreditStale });
machine TestBeamCreditPending { start state Init { entry { new BeamCreditScenario(CreditPending); } } }
test tcBeamCreditPending [main = TestBeamCreditPending]: assert BeamCreditSafety, DirectedProgress in (union BeamCreditSystem, { TestBeamCreditPending });
test tcProbeBeamCreditPending [main = TestBeamCreditPending]: assert BeamCreditSafety, BeamCreditReachability, DirectedProgress in (union BeamCreditSystem, { TestBeamCreditPending });
machine TestBeamCreditShared { start state Init { entry { new BeamCreditScenario(CreditShared); } } }
test tcBeamCreditShared [main = TestBeamCreditShared]: assert BeamCreditSafety, DirectedProgress in (union BeamCreditSystem, { TestBeamCreditShared });
test tcProbeBeamCreditShared [main = TestBeamCreditShared]: assert BeamCreditSafety, BeamCreditReachability, DirectedProgress in (union BeamCreditSystem, { TestBeamCreditShared });
machine TestBeamCreditLost { start state Init { entry { new BeamCreditScenario(CreditLost); } } }
test tcBeamCreditLost [main = TestBeamCreditLost]: assert BeamCreditSafety, DirectedProgress in (union BeamCreditSystem, { TestBeamCreditLost });
test tcProbeBeamCreditLost [main = TestBeamCreditLost]: assert BeamCreditSafety, BeamCreditReachability, DirectedProgress in (union BeamCreditSystem, { TestBeamCreditLost });

machine TestBeamScopeFence { start state Init { entry { new BeamCreditScenario(CreditScopeFence); } } }
test tcBeamScopeFence [main = TestBeamScopeFence]: assert BeamCreditSafety, DirectedProgress in (union BeamCreditSystem, { TestBeamScopeFence });
test tcProbeBeamScopeFence [main = TestBeamScopeFence]: assert BeamCreditSafety, BeamCreditReachability, DirectedProgress in (union BeamCreditSystem, { TestBeamScopeFence });

machine TestBeamScopePending { start state Init { entry { new BeamCreditScenario(CreditScopePending); } } }
test tcBeamScopePending [main = TestBeamScopePending]: assert BeamCreditSafety, DirectedProgress in (union BeamCreditSystem, { TestBeamScopePending });
test tcProbeBeamScopePending [main = TestBeamScopePending]: assert BeamCreditSafety, BeamCreditReachability, DirectedProgress in (union BeamCreditSystem, { TestBeamScopePending });

machine TestBeamScopeLost { start state Init { entry { new BeamCreditScenario(CreditScopeLost); } } }
test tcBeamScopeLost [main = TestBeamScopeLost]: assert BeamCreditSafety, DirectedProgress in (union BeamCreditSystem, { TestBeamScopeLost });
test tcProbeBeamScopeLost [main = TestBeamScopeLost]: assert BeamCreditSafety, BeamCreditReachability, DirectedProgress in (union BeamCreditSystem, { TestBeamScopeLost });

machine TestBeamScopeStale { start state Init { entry { new BeamCreditScenario(CreditScopeStale); } } }
test tcBeamScopeStale [main = TestBeamScopeStale]: assert BeamCreditSafety, DirectedProgress in (union BeamCreditSystem, { TestBeamScopeStale });
test tcProbeBeamScopeStale [main = TestBeamScopeStale]: assert BeamCreditSafety, BeamCreditReachability, DirectedProgress in (union BeamCreditSystem, { TestBeamScopeStale });

machine TestBeamScopeIdle { start state Init { entry { new BeamCreditScenario(CreditScopeIdle); } } }
test tcBeamScopeIdle [main = TestBeamScopeIdle]: assert BeamCreditSafety, DirectedProgress in (union BeamCreditSystem, { TestBeamScopeIdle });
test tcProbeBeamScopeIdle [main = TestBeamScopeIdle]: assert BeamCreditSafety, BeamCreditReachability, DirectedProgress in (union BeamCreditSystem, { TestBeamScopeIdle });

machine TestBeamScopeOwner { start state Init { entry { new BeamCreditScenario(CreditScopeOwner); } } }
test tcBeamScopeOwner [main = TestBeamScopeOwner]: assert BeamCreditSafety, DirectedProgress in (union BeamCreditSystem, { TestBeamScopeOwner });
test tcProbeBeamScopeOwner [main = TestBeamScopeOwner]: assert BeamCreditSafety, BeamCreditReachability, DirectedProgress in (union BeamCreditSystem, { TestBeamScopeOwner });
