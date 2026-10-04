// Probes intentionally fail with a specific marker. The local runner never
// accepts a checker crash or compiler failure as a reachability witness.
spec ProbeSuccess observes mWitness {
  start state Watching {
    on mWitness do (p: tWitness) { assert p != Success, "witness: successful receipt cleanup and epoch GC"; }
  }
}
spec ProbeUncertain observes mAnswer {
  start state Watching {
    on mAnswer do (p: tReply) {
      assert !(p.answer == Prior && p.row.phase == Intent && p.boot > p.row.launchBoot),
        "witness: crash retained uncertain launch across reboot";
    }
  }
}
spec ProbeReuse observes mWitness {
  start state Watching {
    on mWitness do (p: tWitness) { assert p != Reuse, "witness: delayed stale cancel reached reused helper"; }
  }
}
spec ProbePressure observes mWitness {
  start state Watching {
    on mWitness do (p: tWitness) { assert p != Pressure, "witness: evidence capacity refused new admission"; }
  }
}
spec ProbeClosedReconcile observes mWitness {
  start state Watching {
    on mWitness do (p: tWitness) { assert p != ClosedReconcile, "witness: closed epoch reconciled retained ID"; }
  }
}
spec ProbeConflict observes mWitness {
  start state Watching {
    on mWitness do (p: tWitness) { assert p != ConflictSeen, "witness: changed request digest conflicted"; }
  }
}
spec ProbeReceiptLoss observes mWitness {
  start state Watching {
    on mWitness do (p: tWitness) { assert p != ReceiptLost, "witness: durable owner receipt lost in transport"; }
  }
}
spec ProbeCancelLoss observes mWitness {
  start state Watching {
    on mWitness do (p: tWitness) { assert p != CancelLost, "witness: cancel lost without native retirement"; }
  }
}
test tcProbeSuccess [main = TestLifecycle]: assert ProbeSuccess in (union System, { TestLifecycle });
test tcProbeCrashAfterSend [main = TestCrashAfterSend]: assert ProbeUncertain in (union System, { TestCrashAfterSend });
test tcProbeUncertain [main = UncertainScenario]: assert ProbeUncertain in System;
test tcProbeReuse [main = TestLifecycle]: assert ProbeReuse in (union System, { TestLifecycle });
test tcProbePressure [main = TestLifecycle]: assert ProbePressure in (union System, { TestLifecycle });
test tcProbeClosedReconcile [main = UncertainScenario]: assert ProbeClosedReconcile in System;
test tcProbeConflict [main = TestLifecycle]: assert ProbeConflict in (union System, { TestLifecycle });
test tcProbeReceiptLoss [main = FaultScenario]: assert ProbeReceiptLoss in System;
test tcProbeCancelLoss [main = FaultScenario]: assert ProbeCancelLoss in System;

spec ProbeLiveRestart observes mStart, mRecovered {
  var started: set[tKey];
  start state Watching {
    on mStart do (p: tNative) { started += (p.key); }
    on mRecovered do (p: (boot: int, rows: map[tKey, tRow])) {
      var ks: seq[tKey];
      var i: int;
      ks = keys(p.rows);
      i = 0;
      while (i < sizeof(ks)) {
        assert !(ks[i] in started && p.rows[ks[i]].phase == Running),
          "witness: reboot preserved custody of actually running native execution";
        i = i + 1;
      }
    }
  }
}
spec ProbeAdmissionLoss observes mWitness {
  start state Watching {
    on mWitness do (p: tWitness) { assert p != AdmissionLost, "witness: admission request lost in transport"; }
  }
}
spec ProbeResultLoss observes mWitness {
  start state Watching {
    on mWitness do (p: tWitness) { assert p != ResultLost, "witness: terminal result lost in transport"; }
  }
}
test tcProbeLiveRestart [main = TestLifecycle]: assert ProbeLiveRestart in (union System, { TestLifecycle });
test tcProbeAdmissionLoss [main = FaultScenario]: assert ProbeAdmissionLoss in System;
test tcProbeResultLoss [main = FaultScenario]: assert ProbeResultLoss in System;

spec ProbeAdmissionAckLoss observes mWitness {
  start state Watching {
    on mWitness do (p: tWitness) {
      assert p != AdmissionAckLost, "witness: admission acknowledgement lost after durable commit";
    }
  }
}
test tcProbeAdmissionAckLoss [main = FaultScenario]: assert ProbeAdmissionAckLoss in System;
