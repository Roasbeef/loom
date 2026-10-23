// Reachability probes for the evolution path. Each asserts that one situation
// never happens, so each is expected to fail: the checker found a witness. They
// guard against a vacuous model, as Probes.p does for the execution machines.

// The migration was applied: the whole path from stage to publish is reached.
spec ProbeMigrationApplied observes eMigrated {
  start state Watching {
    on eMigrated do (p: (handle: int, target: int)) {
      assert false, "witness: a migration was applied";
    }
  }
}

// A stage sent again after a dropped connection answered the generation that
// already existed.
spec ProbeStageResentJoins observes eStageJoined {
  start state Watching {
    on eStageJoined do (resent: bool) {
      assert !resent, "witness: a re-sent stage joined a live generation";
    }
  }
}

// A runtime restarted inside an open and its stage joined the generation the
// dead runtime started.
spec ProbeStageAfterRestartJoins observes eStageJoined {
  start state Watching {
    on eStageJoined do (resent: bool) {
      assert resent, "witness: a stage from a new runtime joined a live generation";
    }
  }
}

// A publish sent again after a lost reply was answered without migrating again.
spec ProbePublishResentJoins observes ePublishJoined {
  start state Watching {
    on ePublishJoined do (resent: bool) {
      assert !resent, "witness: a re-sent publish answered the same receipt";
    }
  }
}

// An abort named a successor the plane no longer holds for that handle (a later
// prepare replaced it) and did nothing.
spec ProbeAbortStale observes eAbortStale {
  start state Watching {
    on eAbortStale do (handle: int) {
      assert false, "witness: an abort of a replaced successor was a no-op";
    }
  }
}

// A publish carrying a stale incarnation or token was refused.
spec ProbeStalePublishRefused observes eStaleRefused {
  start state Watching {
    on eStaleRefused do (op: tOp) {
      assert op != OP_PUBLISH, "witness: a stale publish was refused";
    }
  }
}

// A stage carrying a stale incarnation or token was refused.
spec ProbeStaleStageRefused observes eStaleRefused {
  start state Watching {
    on eStaleRefused do (op: tOp) {
      assert op != OP_STAGE, "witness: a stale stage was refused";
    }
  }
}

// A new open found the selection already moved to generation 2 by a committed
// compare-and-set and staged it.
spec ProbeRecoveryStagesCommitted observes eRecoveryStage {
  start state Watching {
    on eRecoveryStage do (g: int) {
      assert false, "witness: a new open staged a selection a dead owner committed";
    }
  }
}

// A stage for a generation older than a live one was refused: a dead runtime's
// stage arrived after the selection moved on.
spec ProbeStaleGenerationRefused observes eStaleGeneration {
  start state Watching {
    on eStaleGeneration do (g: int) {
      assert false, "witness: a stage for an older generation was refused";
    }
  }
}

// A stage superseded an older generation of the slot and reported it.
spec ProbeStageSupersedes observes eSuperseded {
  start state Watching {
    on eSuperseded do (n: int) {
      assert false, "witness: a stage superseded an older generation";
    }
  }
}

// A compare-and-set reply was lost and the owner read the durable receipt.
spec ProbeCasReconciled observes eCasReconciled {
  start state Watching {
    on eCasReconciled do (p: tRPhase) {
      assert p != R_COMMITTED, "witness: a lost compare-and-set reply was reconciled as committed";
    }
  }
}

// A retirement was not confirmed and its obligation was kept.
spec ProbeCleanupUnconfirmed observes eCleanupUnconfirmed {
  start state Watching {
    on eCleanupUnconfirmed do (h: int) {
      assert false, "witness: a retirement was not confirmed";
    }
  }
}

// A generation was lost with the executor's VM.
spec ProbeGenerationLostInCrash observes eVmCrashed, eInstStarted {
  var started: int;

  start state Watching {
    on eInstStarted do (p: (handle: int, gen: int, inc: int)) {
      started = started + 1;
    }

    on eVmCrashed do {
      assert started == 0, "witness: the executor crashed after it started a generation";
    }
  }
}

// A prepare replaced an unpublished successor instead of joining it.
spec ProbePrepareReplaced observes ePrepareReplaced {
  start state Watching {
    on ePrepareReplaced do (s: int) {
      assert false, "witness: a prepare replaced an unpublished successor";
    }
  }
}

// A retire carrying a stale token or incarnation was refused.
spec ProbeStaleRetireRefused observes eStaleRefused {
  start state Watching {
    on eStaleRefused do (op: tOp) {
      assert op != OP_RETIRE, "witness: a stale retire was refused";
    }
  }
}
