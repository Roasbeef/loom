// This is the custodian/storage boundary, not another native executor. Durable
// rows survive reboot; live reports and pinned destinations do not transfer.
enum tRunCustody { RunUnreleased, RunReleased }
enum tRunCollection { RunRetained, RunFrozen }
enum tRunDisposition { RunWaiting, RunFinalCommitted, RunUnresolved }
enum tRunAdmission { RunAdmitting, RunRecoveryOnly }
enum tRunCommit { RunCommitOk, RunCommitFailed }
enum tRunFence { RunWorkerLost, RunConsumerFatal, RunFinalFailure, RunDischargeFailure }
enum tRunAnswer { RunFresh, RunRefused, RunObserved, RunStarted, RunFinalStored,
  RunFenced, RunDrained, RunCollected, RunCollectionPending, RunPinnedRejected, RunCommitRejected, RunRebooted }
enum tRunMode { RunHappy, RunCrashBefore, RunCrashAfter, RunLost, RunFatal,
  RunFinalFails, RunDischargeFails, RunFreshFails }
type tRunPin = (key: int, incarnation: int);
type tRunOrigin = (key: int, incarnation: int, ordinal: int);
type tRunRow = (custody: tRunCustody, collection: tRunCollection, outcome: int);
type tRunReport = (pin: tRunPin, outcome: int, commit: tRunCommit);
type tRunView = (key: int, incarnation: int, admission: tRunAdmission,
  present: bool, row: tRunRow, answer: tRunAnswer);
type tRunBoot = (incarnation: int, admission: tRunAdmission, rows: map[int, tRunRow]);
event eRunAdmit: (key: int, commit: tRunCommit);
event eRunStart: tRunPin;
event eRunFinal: tRunReport;
event eRunDrain: (pin: tRunPin, commit: tRunCommit);
event eRunFence: (pin: tRunPin, cause: tRunFence);
event eRunRestart;
event eRunCollect: int;
event eRunRead: int;
event eRunPinnedChild: tRunOrigin;
event eRunHold: tRunOrigin;
event eRunReceipt: tRunOrigin;
event eRunHeld: tRunOrigin;
event eRunReceiptStored: tRunOrigin;
event eRunReadReceipt: tRunOrigin;
event eRunReceiptRead: tRunOrigin;
event mRunReceiptRead: tRunOrigin;
event eRunView: tRunView;
event mRunScenario: tRunMode;
event mRunReserved: (pin: tRunPin, row: tRunRow);
event mRunFreshFailed: int;
event mRunStarted: tRunPin;
event mRunFinalAttempt: tRunReport;
event mRunDischargeAttempt: (pin: tRunPin, commit: tRunCommit);
event mRunFinalCommitted: (pin: tRunPin, outcome: int);
event mRunDrainObserved: tRunPin;
event mRunFenced: (pin: tRunPin, cause: tRunFence);
event mRunDischargeFailed: tRunPin;
event mRunReleased: (pin: tRunPin, outcome: int);
event mRunBoot: tRunBoot;
event mRunAdmissionRefused: tRunPin;
event mRunCollectionPending: int;
event mRunCollected: int;
event mRunHistory: tRunView;
event mRunPinnedRejected: tRunPin;
event mRunChildForwarded: tRunOrigin;
event mRunHeld: tRunOrigin;
event mRunLateReceipt: tRunOrigin;

machine RunCustodian {
  var driver: machine;
  var downstream: machine;
  var incarnation: int;
  var admission: tRunAdmission;
  var rows: map[int, tRunRow];
  var live: map[int, tRunDisposition];
  var finals: map[int, int];
  var drained: set[int];
  start state Init {
    entry (p: (driver: machine, downstream: machine)) {
      driver = p.driver; downstream = p.downstream;
      incarnation = 1; admission = RunAdmitting; goto Ready;
    }
  }
  state Ready {
    on eRunAdmit do (p: (key: int, commit: tRunCommit)) {
      var pin: tRunPin;
      pin = (key = p.key, incarnation = incarnation);
      if (admission != RunAdmitting || sizeof(live) == 1 || p.key in rows) {
        announce mRunAdmissionRefused, pin; reply(p.key, RunRefused); return;
      }
      if (p.commit == RunCommitFailed) {
        announce mRunFreshFailed, p.key; reply(p.key, RunCommitRejected); return;
      }
      // This atomic reservation is the durable prerequisite of the spawn turn.
      rows[p.key] = (custody = RunUnreleased, collection = RunRetained, outcome = 0);
      announce mRunReserved, (pin = pin, row = rows[p.key]);
      live[p.key] = RunWaiting; reply(p.key, RunFresh);
    }
    on eRunStart do (pin: tRunPin) {
      if (pin.incarnation != incarnation || !(pin.key in live)) {
        announce mRunPinnedRejected, pin; reply(pin.key, RunPinnedRejected); return;
      }
      announce mRunStarted, pin; reply(pin.key, RunStarted);
    }
    on eRunFinal do (p: tRunReport) {
      if (p.pin.incarnation != incarnation || !(p.pin.key in live)) {
        announce mRunPinnedRejected, p.pin; reply(p.pin.key, RunPinnedRejected); return;
      }
      announce mRunFinalAttempt, p;
      if (p.commit == RunCommitFailed ||
          (rows[p.pin.key].outcome != 0 && rows[p.pin.key].outcome != p.outcome)) {
        fence(p.pin, RunFinalFailure); reply(p.pin.key, RunCommitRejected); return;
      }
      rows[p.pin.key].outcome = p.outcome;
      announce mRunFinalCommitted, (pin = p.pin, outcome = rows[p.pin.key].outcome);
      // An ordinary final result may survive for history after a fatal report.
      // It cannot replace the live owner's sticky unresolved disposition.
      if (live[p.pin.key] == RunWaiting) {
        live[p.pin.key] = RunFinalCommitted; finals[p.pin.key] = p.outcome;
      }
      reply(p.pin.key, RunFinalStored);
    }
    on eRunFence do (p: (pin: tRunPin, cause: tRunFence)) {
      if (p.pin.incarnation != incarnation || !(p.pin.key in live)) {
        announce mRunPinnedRejected, p.pin; reply(p.pin.key, RunPinnedRejected); return;
      }
      fence(p.pin, p.cause); reply(p.pin.key, RunFenced);
    }
    on eRunDrain do (p: (pin: tRunPin, commit: tRunCommit)) {
      if (p.pin.incarnation != incarnation || !(p.pin.key in live)) {
        announce mRunPinnedRejected, p.pin; reply(p.pin.key, RunPinnedRejected); return;
      }
      drained += (p.pin.key); announce mRunDrainObserved, p.pin;
      discharge(p.pin, p.commit); reply(p.pin.key, RunDrained);
    }
    on eRunRestart do {
      incarnation = incarnation + 1;
      live = default(map[int, tRunDisposition]); finals = default(map[int, int]);
      drained = default(set[int]); admission = RunAdmitting;
      if (hasUnreleased()) { admission = RunRecoveryOnly; }
      announce mRunBoot, (incarnation = incarnation, admission = admission, rows = rows);
      reply(1, RunRebooted);
    }
    on eRunCollect do (id: int) {
      if (!(id in rows) || rows[id].custody != RunReleased) {
        announce mRunCollectionPending, id; reply(id, RunCollectionPending); return;
      }
      rows[id].collection = RunFrozen; rows[id].outcome = 0;
      announce mRunCollected, id; reply(id, RunCollected);
    }
    on eRunRead do (id: int) {
      announce mRunHistory, view(id, RunObserved); reply(id, RunObserved);
    }
    on eRunPinnedChild do (origin: tRunOrigin) {
      // A retained parent is sufficient for child custody, but the runner's
      // private Subject/PID must still resolve only its original incarnation.
      if (origin.incarnation != incarnation) {
        announce mRunPinnedRejected, (key = origin.key, incarnation = origin.incarnation);
        reply(origin.key, RunPinnedRejected); return;
      }
      if (!(origin.key in rows)) { reply(origin.key, RunRefused); return; }
      announce mRunChildForwarded, origin; send downstream, eRunHold, origin;
    }
  }
  fun fence(pin: tRunPin, cause: tRunFence) {
    live[pin.key] = RunUnresolved; admission = RunRecoveryOnly;
    announce mRunFenced, (pin = pin, cause = cause);
  }
  fun discharge(pin: tRunPin, commit: tRunCommit) {
    if (live[pin.key] != RunFinalCommitted || !(pin.key in drained)) { return; }
    if (!(pin.key in finals) || rows[pin.key].outcome != finals[pin.key]) { return; }
    announce mRunDischargeAttempt, (pin = pin, commit = commit);
    if (commit == RunCommitFailed) {
      announce mRunDischargeFailed, pin; fence(pin, RunDischargeFailure); return;
    }
    rows[pin.key].custody = RunReleased;
    announce mRunReleased, (pin = pin, outcome = finals[pin.key]);
    live -= (pin.key); finals -= (pin.key); drained -= (pin.key);
  }
  fun hasUnreleased(): bool {
    var ids: seq[int]; var i: int;
    ids = keys(rows); i = 0;
    while (i < sizeof(ids)) {
      if (rows[ids[i]].custody != RunReleased) { return true; }
      i = i + 1;
    }
    return false;
  }
  fun view(id: int, answer: tRunAnswer): tRunView {
    var row: tRunRow;
    if (id in rows) { row = rows[id]; }
    return (key = id, incarnation = incarnation, admission = admission,
      present = id in rows, row = row, answer = answer);
  }
  fun reply(id: int, answer: tRunAnswer) { send driver, eRunView, view(id, answer); }
}

// Accepted downstream custody outlives both the managed worker and its owner.
// An exact late receipt writes evidence; it supplies no owner-run drain proof.
machine RunDownstream {
  var driver: machine;
  var pending: set[tRunOrigin];
  var terminals: set[tRunOrigin];
  start state Ready {
    entry (p: machine) { driver = p; }
    on eRunHold do (origin: tRunOrigin) {
      pending += (origin); announce mRunHeld, origin; send driver, eRunHeld, origin;
    }
    on eRunReceipt do (origin: tRunOrigin) {
      assert origin in pending, "late receipt changed accepted downstream origin";
      pending -= (origin); terminals += (origin); announce mRunLateReceipt, origin;
      send driver, eRunReceiptStored, origin;
    }
    on eRunReadReceipt do (origin: tRunOrigin) {
      assert origin in terminals, "late exact receipt was not retained for history";
      announce mRunReceiptRead, origin; send driver, eRunReceiptRead, origin;
    }
  }
}
