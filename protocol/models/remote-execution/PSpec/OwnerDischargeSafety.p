// These histories come from the owner/store and downstream actors' decisions.
// A scenario's step number is never accepted as evidence of commit or drain.
spec OwnerDischargeSafety observes mRunReserved, mRunStarted, mRunFinalCommitted,
  mRunDrainObserved, mRunFenced, mRunReleased, mRunBoot, mRunCollected,
  mRunChildForwarded, mRunHistory, mRunFinalAttempt, mRunDischargeAttempt,
  mRunHeld, mRunLateReceipt, mRunReceiptRead {
  var incarnation: int;
  var admission: tRunAdmission;
  var rows: map[int, tRunRow];
  var live: set[tRunPin];
  var started: set[tRunPin];
  var finals: map[tRunPin, int];
  var drained: set[tRunPin];
  var unresolved: set[tRunPin];
  var finalAttempts: map[tRunPin, tRunReport];
  var dischargeAttempts: map[tRunPin, tRunCommit];
  var held: set[tRunOrigin]; var receipts: set[tRunOrigin];
  start state Watching {
    entry { incarnation = 1; admission = RunAdmitting; }
    on mRunReserved do (p: (pin: tRunPin, row: tRunRow)) {
      assert admission == RunAdmitting && sizeof(live) == 0,
        "fresh admission reopened unresolved owner capacity";
      assert !(p.pin.key in rows) && p.pin.incarnation == incarnation,
        "fresh reservation reused retained key or wrong incarnation";
      assert p.row.custody == RunUnreleased, "Fresh COMMIT omitted unreleased custody";
      rows[p.pin.key] = p.row; live += (p.pin);
    }
    on mRunStarted do (pin: tRunPin) {
      assert pin in live && pin.incarnation == incarnation &&
        rows[pin.key].custody == RunUnreleased,
        "worker started before durable unreleased reservation";
      assert !(pin in started), "same owner run started twice";
      started += (pin);
    }
    on mRunFinalAttempt do (p: tRunReport) { finalAttempts[p.pin] = p; }
    on mRunDischargeAttempt do (p: (pin: tRunPin, commit: tRunCommit)) { dischargeAttempts[p.pin] = p.commit; }
    on mRunFinalCommitted do (p: (pin: tRunPin, outcome: int)) {
      assert p.pin in finalAttempts && finalAttempts[p.pin].commit == RunCommitOk &&
        finalAttempts[p.pin].outcome == p.outcome, "final outcome committed after failed or changed transaction";
      assert p.pin in started && p.pin.incarnation == incarnation,
        "final commit lacked original live worker";
      assert rows[p.pin.key].outcome == 0 || rows[p.pin.key].outcome == p.outcome,
        "retained final outcome changed exact bytes";
      rows[p.pin.key].outcome = p.outcome; finals[p.pin] = p.outcome;
    }
    on mRunDrainObserved do (pin: tRunPin) {
      assert pin in live && pin.incarnation == incarnation,
        "historical drain became current owner authority";
      drained += (pin);
    }
    on mRunFenced do (p: (pin: tRunPin, cause: tRunFence)) {
      unresolved += (p.pin); admission = RunRecoveryOnly;
    }
    on mRunReleased do (p: (pin: tRunPin, outcome: int)) {
      assert p.pin in live && p.pin.incarnation == incarnation &&
        p.pin in finals && finals[p.pin] == p.outcome && rows[p.pin.key].outcome == p.outcome,
        "release lacked same-incarnation exact final commit";
      assert p.pin in drained, "owner custody released before AllDelivered";
      assert !(p.pin in unresolved), "sticky unresolved disposition was overwritten";
      assert p.pin in dischargeAttempts && dischargeAttempts[p.pin] == RunCommitOk,
        "failed discharge COMMIT released owner custody";
      assert rows[p.pin.key].custody == RunUnreleased, "owner custody released twice";
      rows[p.pin.key].custody = RunReleased; live -= (p.pin);
    }
    on mRunBoot do (p: tRunBoot) {
      var ids: seq[int]; var i: int; var pending: bool;
      assert p.rows == rows, "owner reboot changed durable custody or outcome";
      assert p.incarnation == incarnation + 1, "owner reboot reused live incarnation";
      ids = keys(rows); i = 0;
      while (i < sizeof(ids)) {
        if (rows[ids[i]].custody != RunReleased) { pending = true; }
        i = i + 1;
      }
      assert !pending || p.admission == RunRecoveryOnly,
        "owner startup reopened unreleased admission";
      incarnation = p.incarnation; admission = p.admission;
      live = default(set[tRunPin]);
    }
    on mRunCollected do (id: int) {
      assert id in rows && rows[id].custody == RunReleased,
        "collection erased unreleased outcome or marker";
      rows[id].collection = RunFrozen; rows[id].outcome = 0;
    }
    on mRunChildForwarded do (origin: tRunOrigin) {
      assert origin.incarnation == incarnation,
        "old pinned runner rebound to replacement owner";
      assert origin.key in rows, "child forward lacked retained parent";
    }
    on mRunHeld do (origin: tRunOrigin) { held += (origin); }
    on mRunLateReceipt do (origin: tRunOrigin) {
      assert origin in held, "late receipt changed independently accepted child";
      receipts += (origin);
    }
    on mRunReceiptRead do (origin: tRunOrigin) {
      assert origin in receipts, "historical read fabricated exact late receipt";
    }
    on mRunHistory do (v: tRunView) {
      assert v.present == (v.key in rows), "history changed retained owner row presence";
      if (v.present) { assert v.row == rows[v.key], "history changed exact owner outcome or marker"; }
    }
  }
}

// Positive witnesses require independently announced facts and completed replies.
// The mode selects the claim; it is not one of the facts satisfying that claim.
spec OwnerDischargeReachability observes mRunScenario, mRunReserved, mRunFreshFailed,
  mRunStarted, mRunFinalCommitted, mRunDrainObserved, mRunFenced, mRunReleased,
  mRunBoot, mRunAdmissionRefused, mRunCollectionPending, mRunCollected,
  mRunHistory, mRunPinnedRejected, mRunHeld, mRunLateReceipt, mRunReceiptRead, mRunDischargeFailed, mScenarioEnd {
  var mode: tRunMode;
  var reserved: set[int]; var started: set[int]; var final: set[int];
  var drained: set[int]; var released: set[int]; var collected: set[int];
  var pending: set[int]; var refused: set[int];
  var recovery: bool; var admitting: bool; var historical: bool; var stale: bool;
  var held: bool; var receipt: bool; var receiptRead: bool; var lost: bool; var fatal: bool;
  var finalFailed: bool; var dischargeFailed: bool; var freshFailed: bool;
  start state Watching {
    on mRunScenario do (p: tRunMode) { mode = p; }
    on mRunReserved do (p: (pin: tRunPin, row: tRunRow)) { reserved += (p.pin.key); }
    on mRunFreshFailed do (id: int) { freshFailed = id == 1; }
    on mRunStarted do (pin: tRunPin) { started += (pin.key); }
    on mRunFinalCommitted do (p: (pin: tRunPin, outcome: int)) { final += (p.pin.key); }
    on mRunDrainObserved do (pin: tRunPin) { drained += (pin.key); }
    on mRunReleased do (p: (pin: tRunPin, outcome: int)) { released += (p.pin.key); }
    on mRunBoot do (p: tRunBoot) {
      recovery = p.admission == RunRecoveryOnly;
      admitting = p.admission == RunAdmitting;
    }
    on mRunAdmissionRefused do (pin: tRunPin) { refused += (pin.key); }
    on mRunCollectionPending do (id: int) { pending += (id); }
    on mRunCollected do (id: int) { collected += (id); }
    on mRunHistory do (v: tRunView) { historical = v.present && v.row.outcome == 1 && v.row.custody == RunUnreleased; }
    on mRunPinnedRejected do (pin: tRunPin) { stale = pin.incarnation == 1; }
    on mRunHeld do (origin: tRunOrigin) { held = origin.key == 1 && origin.ordinal == 1; }
    on mRunLateReceipt do (origin: tRunOrigin) { receipt = held && origin.key == 1 && origin.ordinal == 1; }
    on mRunReceiptRead do (origin: tRunOrigin) { receiptRead = receipt && origin.key == 1 && origin.ordinal == 1; }
    on mRunDischargeFailed do (pin: tRunPin) { dischargeFailed = pin.key == 1; }
    on mRunFenced do (p: (pin: tRunPin, cause: tRunFence)) {
      if (p.cause == RunWorkerLost) { lost = true; }
      if (p.cause == RunConsumerFatal) { fatal = true; }
      if (p.cause == RunFinalFailure) { finalFailed = true; }
    }
    on mScenarioEnd do {
      if (mode == RunHappy) {
        assert !(1 in final && 1 in drained && 1 in released && 1 in pending &&
          1 in collected && admitting && 2 in released),
          "witness: exact live finish and drain released collected custody and admitted next run";
      } else if (mode == RunCrashBefore) {
        assert !(1 in reserved && !(1 in started) && recovery && 2 in refused && stale),
          "witness: Fresh commit before spawn survived crash and refused admission and old start";
      } else if (mode == RunCrashAfter) {
        assert !(1 in final && !(1 in released) && recovery && historical &&
          1 in pending && 2 in refused && stale),
          "witness: final commit before drain remained historical after restart without release";
      } else if (mode == RunLost) {
        assert !(held && lost && 1 in drained && recovery && 2 in refused && stale && receiptRead && !(1 in released)),
          "witness: held downstream survived worker loss restart late receipt and pinned refusal";
      } else if (mode == RunFatal) {
        assert !(fatal && 1 in final && 1 in drained && !(1 in released) && recovery && 2 in refused),
          "witness: consumer fatal stayed sticky after exact final drain and restart";
      } else if (mode == RunFinalFails) {
        assert !(finalFailed && !(1 in final) && 1 in drained && recovery && 2 in refused),
          "witness: failed final COMMIT retained unreleased custody across drain and restart";
      } else if (mode == RunDischargeFails) {
        assert !(1 in final && 1 in drained && dischargeFailed && !(1 in released) && recovery && 2 in refused),
          "witness: failed discharge COMMIT retained slot and fenced restart admission";
      } else {
        assert !(freshFailed && !(1 in reserved) && !(1 in started) && 2 in reserved && 2 in released),
          "witness: failed Fresh COMMIT spawned no worker and genuine later admission completed";
      }
    }
  }
}
