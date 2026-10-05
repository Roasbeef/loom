// Every step waits for a concrete endpoint reply. A delayed handoff may arrive
// after drain; no cross-sender signal-delivery ordering is assumed.
type tCreditStep = (command: tCreditCommand, outcome: tCreditOutcome,
  dataSlots: int, control: int, expectedRun: int);
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
        v.control == steps[index].control && v.run == steps[index].expectedRun,
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
      outcome = outcome, dataSlots = dataSlots, control = control, expectedRun = expectedRun));
  }

  fun act(action: tCreditAction, slot: int, run: int, dataSlots: int, control: int, expectedRun: int) {
    add(action, slot, run, 1, CreditData, CreditStepped, dataSlots, control, expectedRun);
  }

  fun script() {
    var i: int;
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
