// These histories come from the owner/store and downstream actors' decisions.
// A scenario's step number is never accepted as evidence of commit or drain.
spec OwnerDischargeSafety observes mRunReserved, mRunStarted, mRunFinalCommitted,
  mRunDrainObserved, mRunFenced, mRunReleased, mRunBoot, mRunCollected,
  mRunChildForwarded, mRunHistory, mRunFinalAttempt, mRunDischargeAttempt,
  mRunProfileChosen, mRunReportAttempt, mRunReportCommitted, mRunReferenceAttempt,
  mRunSessionCommitted, mRunCollectionValue, mRunRefusalProduced, mRunRefusalAttempt,
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
  var selected: map[int, tFinalProfile];
  var reportAttempts: map[tRunPin, tRetainReport];
  var references: map[tRunPin, tReferenceFinal];
  var refusalProducers: map[tRunPin, tPrelaunchRefusal];
  var refusalAttempts: map[tRunPin, tRefusalFinal];
  start state Watching {
    entry { incarnation = 1; admission = RunAdmitting; }
    on mRunRefusalProduced do (p: tRefusalWitness) { refusalProducers[p.pin] = p.stage; }
    on mRunRefusalAttempt do (p: tRefusalFinal) { refusalAttempts[p.pin] = p; }
    on mRunProfileChosen do (p: (key: int, profile: tFinalProfile)) { selected[p.key] = p.profile; }
    on mRunReserved do (p: (pin: tRunPin, row: tRunRow)) {
      var charged: int; var ids: seq[int]; var i: int; var expected: int;
      assert admission == RunAdmitting && sizeof(live) == 0,
        "fresh admission reopened unresolved owner capacity";
      assert !(p.pin.key in rows) && p.pin.incarnation == incarnation,
        "fresh reservation reused retained key or wrong incarnation";
      assert p.row.custody == RunUnreleased, "Fresh COMMIT omitted unreleased custody";
      assert p.pin.key in selected && selected[p.pin.key] == p.row.profile,
        "Fresh reservation changed trusted final profile";
      expected = 262144;
      if (p.row.profile == CodeModeReportV1) { expected = 17301648; }
      assert p.row.allowance == expected && p.row.charge == expected,
        "Fresh reservation omitted full final allowance";
      assert p.row.report == default(tSavedReport) && p.row.sessionFinal == 0,
        "Fresh reservation fabricated retained report or session commit";
      ids = keys(rows);
      while (i < sizeof(ids)) { charged = charged + rows[ids[i]].charge; i = i + 1; }
      assert charged + expected <= 34603296, "Fresh reservation exceeded retained quota";
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
    on mRunReportAttempt do (p: tRetainReport) { reportAttempts[p.pin] = p; }
    on mRunReferenceAttempt do (p: tReferenceFinal) { references[p.pin] = p; }
    on mRunReportCommitted do (p: (pin: tRunPin, report: tSavedReport)) {
      assert p.pin in live && p.pin in started && p.pin.incarnation == incarnation,
        "report COMMIT lacked original live worker";
      assert p.pin in reportAttempts && reportAttempts[p.pin].commit == RunCommitOk &&
        reportAttempts[p.pin].report == p.report, "report committed after failed or changed transaction";
      assert rows[p.pin.key].profile == CodeModeReportV1 &&
        rows[p.pin.key].allowance == 17301648 && rows[p.pin.key].charge == 17301648,
        "report storage escaped its preeffect profile reservation";
      assert p.report.identity == p.pin.key && p.report.digest > 0 &&
        p.report.bytes > 0 && p.report.bytes <= 17039376,
        "report COMMIT changed original identity or exceeded bundle bound";
      assert rows[p.pin.key].report.bytes == 0 || rows[p.pin.key].report == p.report,
        "report COMMIT replaced original complete value";
      rows[p.pin.key].report = p.report;
    }
    on mRunSessionCommitted do (p: (key: int, outcome: int)) {
      assert p.key in rows && p.outcome != 0 && rows[p.key].outcome == p.outcome,
        "session readback differs from exact owner final";
      rows[p.key].sessionFinal = p.outcome;
    }
    on mRunFinalCommitted do (p: (pin: tRunPin, outcome: int)) {
      assert p.pin in finalAttempts && finalAttempts[p.pin].commit == RunCommitOk &&
        finalAttempts[p.pin].outcome == p.outcome, "final outcome committed after failed or changed transaction";
      assert p.pin in started && p.pin.incarnation == incarnation,
        "final commit lacked original live worker";
      assert rows[p.pin.key].outcome == 0 || rows[p.pin.key].outcome == p.outcome,
        "retained final outcome changed exact bytes";
      if (rows[p.pin.key].report.bytes != 0) {
        assert p.pin in references && references[p.pin].reference == rows[p.pin.key].report &&
          references[p.pin].outcome == p.outcome,
          "final message lacked exact committed report reference";
      }
      if (rows[p.pin.key].profile == CodeModeReportV1 && rows[p.pin.key].report.bytes == 0 &&
          !(p.pin in unresolved)) {
        assert p.pin in refusalProducers && p.pin in refusalAttempts &&
          refusalAttempts[p.pin].stage == refusalProducers[p.pin] &&
          refusalAttempts[p.pin].outcome == p.outcome,
          "report-free final lacked original trusted prelaunch refusal";
      }
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
    on mRunCollectionValue do (p: (key: int, row: tRunRow)) {
      assert p.key in rows && rows[p.key].custody == RunReleased,
        "collection erased unreleased outcome or marker";
      assert p.row.profile == rows[p.key].profile && p.row.allowance == rows[p.key].allowance &&
        p.row.report == rows[p.key].report, "collection erased report identity or bytes";
      if (p.row.profile == CodeModeReportV1) {
        assert rows[p.key].outcome != 0 && rows[p.key].sessionFinal == rows[p.key].outcome,
          "report collection preceded exact session commit";
        assert p.row.charge == p.row.report.bytes + 128,
          "collection lost retained report charge";
      }
      rows[p.key].charge = p.row.charge;
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

// Reachability uses committed owner events and observed retained rows, not the
// driver's instruction counter. The exact expected assertion is a gate input.
spec ReportCustodyReachability observes mReportScenario, mRunReportAttempt,
  mRunReportCommitted, mRunFinalCommitted, mRunDrainObserved, mRunReleased,
  mRunSessionCommitted, mRunCollected, mRunHistory, mRunBoot, mRunAdmissionRefused,
  mRunPinnedRejected, mRunFenced, mScenarioEnd {
  var mode: tReportMode;
  var saved: map[int, tSavedReport]; var finals: set[int]; var drains: set[int];
  var released: set[int]; var session: set[int]; var collected: set[int];
  var last: tRunView; var rebooted: bool; var recovery: bool; var stale: bool;
  var failed: bool; var lost: bool; var refused: set[int]; var thirdRefusals: int;
  start state Watching {
    on mReportScenario do (p: tReportMode) { mode = p; }
    on mRunReportAttempt do (p: tRetainReport) { if (p.replyLost) { lost = true; } }
    on mRunReportCommitted do (p: (pin: tRunPin, report: tSavedReport)) { saved[p.pin.key] = p.report; }
    on mRunFinalCommitted do (p: (pin: tRunPin, outcome: int)) { finals += (p.pin.key); }
    on mRunDrainObserved do (p: tRunPin) { drains += (p.key); }
    on mRunReleased do (p: (pin: tRunPin, outcome: int)) { released += (p.pin.key); }
    on mRunSessionCommitted do (p: (key: int, outcome: int)) { session += (p.key); }
    on mRunCollected do (id: int) { collected += (id); }
    on mRunHistory do (p: tRunView) { last = p; }
    on mRunBoot do (p: tRunBoot) { rebooted = true; recovery = p.admission == RunRecoveryOnly; }
    on mRunAdmissionRefused do (p: tRunPin) {
      refused += (p.key); if (p.key == 3) { thirdRefusals = thirdRefusals + 1; }
    }
    on mRunPinnedRejected do (p: tRunPin) { if (p.incarnation == 1) { stale = true; } }
    on mRunFenced do (p: (pin: tRunPin, cause: tRunFence)) { if (p.cause == RunReportFailure) { failed = true; } }
    on mScenarioEnd do {
      if (mode == ReportHappy) {
        assert !(1 in saved && 1 in finals && 1 in drains && 1 in released &&
          1 in session && 1 in collected && rebooted && !recovery &&
          last.row.report == saved[1] && last.row.charge == saved[1].bytes + 128),
          "witness: exact report final session commit and drain preserved bytes and charge after collection and reboot";
      } else if (mode == ReportLost) {
        assert !(lost && 1 in saved && !(1 in finals) && !(1 in released) && rebooted && recovery && stale &&
          2 in refused && last.row.report == saved[1] && last.row.outcome == 0 && last.row.charge == 17301648),
          "witness: lost report COMMIT reply retained full unknown custody without final reconstruction or replay";
      } else if (mode == ReportQuota) {
        assert !(1 in saved && 2 in saved && saved[1].bytes == 17039376 && saved[2].bytes == 17039376 &&
          1 in released && 2 in released && 1 in session && 1 in collected && thirdRefusals == 2 &&
          last.row.report == saved[1] && last.row.charge == saved[1].bytes + 128),
          "witness: full preeffect quota retained admitted maximum reports and collection kept their byte charge";
      } else {
        assert !(failed && !(1 in saved) && 1 in finals && 1 in drains && !(1 in released) &&
          rebooted && recovery && 2 in refused && last.row.report.bytes == 0 && last.row.custody == RunUnreleased),
          "witness: refused report storage stayed unresolved through later diagnostic drain and restart";
      }
    }
  }
}

spec RefusalReachability observes mRefusalScenario, mRunRefusalProduced,
  mRunFinalCommitted, mRunDrainObserved, mRunReleased, mRunCollected, mScenarioEnd {
  var mode: tRefusalMode; var produced: bool; var final: bool;
  var drained: bool; var released: bool; var collected: bool;
  start state Watching {
    on mRefusalScenario do (p: tRefusalMode) { mode = p; }
    on mRunRefusalProduced do (p: tRefusalWitness) {
      produced = p.pin == (key = 1, incarnation = 1) &&
        ((mode == RefusalVet && p.stage == VetRefused) ||
         (mode == RefusalCompile && p.stage == CompileRefused));
    }
    on mRunFinalCommitted do (p: (pin: tRunPin, outcome: int)) { final = p.pin.key == 1 && p.outcome == 1; }
    on mRunDrainObserved do (p: tRunPin) { drained = p.key == 1; }
    on mRunReleased do (p: (pin: tRunPin, outcome: int)) { released = p.pin.key == 1 && p.outcome == 1; }
    on mRunCollected do (id: int) { collected = id == 1; }
    on mScenarioEnd do {
      if (mode == RefusalVet && produced && final && drained && released && collected) {
        assert false, "reach report refusal vet";
      }
      if (mode == RefusalCompile && produced && final && drained && released && collected) {
        assert false, "reach report refusal compile";
      }
      if (mode == RefusalMissing && !produced && !final && drained && !released) {
        assert false, "reach report refusal missing";
      }
      if (mode == RefusalForged && !produced && !final && drained && !released) {
        assert false, "reach report refusal forged";
      }
    }
  }
}
