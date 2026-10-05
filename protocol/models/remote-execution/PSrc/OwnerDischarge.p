// This is the custodian/storage boundary, not another native executor. Durable
// rows survive reboot; live reports and pinned destinations do not transfer.
enum tRunCustody { RunUnreleased, RunReleased }
enum tRunCollection { RunRetained, RunFrozen }
enum tRunDisposition { RunWaiting, RunFinalCommitted, RunUnresolved }
enum tRunAdmission { RunAdmitting, RunRecoveryOnly }
enum tRunCommit { RunCommitOk, RunCommitFailed }
enum tRunFence { RunWorkerLost, RunConsumerFatal, RunFinalFailure, RunDischargeFailure, RunReportFailure }
enum tPrelaunchRefusal { VetRefused, CompileRefused }
enum tFinalProfile { OrdinaryFinal, CodeModeReportV1 }
enum tRunAnswer { RunFresh, RunRefused, RunObserved, RunStarted, RunFinalStored,
  RunFenced, RunDrained, RunCollected, RunCollectionPending, RunPinnedRejected, RunCommitRejected, RunRebooted,
  RunReportStored, RunReportReplyLost, RunSessionStored, RunRefusalObserved }
enum tRunMode { RunHappy, RunCrashBefore, RunCrashAfter, RunLost, RunFatal,
  RunFinalFails, RunDischargeFails, RunFreshFails }
type tRunPin = (key: int, incarnation: int);
type tRunOrigin = (key: int, incarnation: int, ordinal: int);
// Identity and digest are symbolic atoms. Bytes and reservations are actual byte
// counts; the model does not implement canonical decoding or cryptographic hash.
type tSavedReport = (identity: int, digest: int, bytes: int);
type tRunRow = (custody: tRunCustody, collection: tRunCollection, outcome: int,
  profile: tFinalProfile, allowance: int, charge: int, report: tSavedReport, sessionFinal: int);
type tRunReport = (pin: tRunPin, outcome: int, commit: tRunCommit);
type tRetainReport = (pin: tRunPin, report: tSavedReport, commit: tRunCommit, replyLost: bool);
type tRefusalFinal = (pin: tRunPin, outcome: int, stage: tPrelaunchRefusal, commit: tRunCommit);
type tRefusalWitness = (pin: tRunPin, stage: tPrelaunchRefusal);
type tReferenceFinal = (pin: tRunPin, outcome: int, reference: tSavedReport, commit: tRunCommit);
type tRunView = (key: int, incarnation: int, admission: tRunAdmission,
  present: bool, row: tRunRow, answer: tRunAnswer);
type tRunBoot = (incarnation: int, admission: tRunAdmission, rows: map[int, tRunRow]);
event eRunAdmit: (key: int, commit: tRunCommit);
event eRunAdmitReport: (key: int, commit: tRunCommit);
event eRunRetainReport: tRetainReport;
event eRunRefusalObserved: tRefusalWitness;
event eRunRefusalFinal: tRefusalFinal;
event eRunProduceRefusal: (owner: machine, witness: tRefusalWitness);
event mRunRefusalProduced: tRefusalWitness;
event mRunRefusalAttempt: tRefusalFinal;
event eRunReferenceFinal: tReferenceFinal;
event eRunSessionCommit: (key: int, outcome: int);
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
event mRunProfileChosen: (key: int, profile: tFinalProfile);
event mRunReportAttempt: tRetainReport;
event mRunReportCommitted: (pin: tRunPin, report: tSavedReport);
event mRunReferenceAttempt: tReferenceFinal;
event mRunSessionCommitted: (key: int, outcome: int);
event mRunCollectionValue: (key: int, row: tRunRow);
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
  var refusals: map[tRunPin, tPrelaunchRefusal];
  var drained: set[int];
  start state Init {
    entry (p: (driver: machine, downstream: machine)) {
      driver = p.driver; downstream = p.downstream;
      incarnation = 1; admission = RunAdmitting; goto Ready;
    }
  }
  state Ready {
    on eRunAdmit do (p: (key: int, commit: tRunCommit)) {
      admit(p, OrdinaryFinal);
    }
    on eRunAdmitReport do (p: (key: int, commit: tRunCommit)) {
      admit(p, CodeModeReportV1);
    }
    on eRunStart do (pin: tRunPin) {
      if (pin.incarnation != incarnation || !(pin.key in live)) {
        announce mRunPinnedRejected, pin; reply(pin.key, RunPinnedRejected); return;
      }
      announce mRunStarted, pin; reply(pin.key, RunStarted);
    }
    on eRunFinal do (p: tRunReport) {
      if (p.pin.key in rows && (rows[p.pin.key].report.bytes != 0 ||
          (rows[p.pin.key].profile == CodeModeReportV1 &&
           (!(p.pin.key in live) || live[p.pin.key] != RunUnresolved)))) {
        reply(p.pin.key, RunCommitRejected); return;
      }
      // A failed-retention diagnostic may enter history, but its sticky fence
      // cannot become successful discharge through this ordinary final path.
      final(p);
    }
    on eRunRefusalObserved do (p: tRefusalWitness) {
      if (p.pin.incarnation != incarnation || !(p.pin.key in live)) {
        announce mRunPinnedRejected, p.pin; reply(p.pin.key, RunPinnedRejected); return;
      }
      // This message is issued only by the trusted vet/compile branch. It is
      // not program output and does not stand in for a compiler child's drain.
      refusals[p.pin] = p.stage; reply(p.pin.key, RunRefusalObserved);
    }
    on eRunRefusalFinal do (p: tRefusalFinal) {
      announce mRunRefusalAttempt, p;
      if (!(p.pin.key in rows) || rows[p.pin.key].profile != CodeModeReportV1 ||
          rows[p.pin.key].report.bytes != 0 ||
          !(p.pin in refusals) || refusals[p.pin] != p.stage) {
        reply(p.pin.key, RunCommitRejected); return;
      }
      final((pin = p.pin, outcome = p.outcome, commit = p.commit));
    }
    on eRunReferenceFinal do (p: tReferenceFinal) {
      announce mRunReferenceAttempt, p;
      if (!(p.pin.key in rows) || rows[p.pin.key].profile != CodeModeReportV1 ||
          p.reference.bytes == 0 || rows[p.pin.key].report != p.reference) {
        reply(p.pin.key, RunCommitRejected); return;
      }
      final((pin = p.pin, outcome = p.outcome, commit = p.commit));
    }
    on eRunRetainReport do (p: tRetainReport) {
      if (p.pin.incarnation != incarnation || !(p.pin.key in live)) {
        announce mRunPinnedRejected, p.pin; reply(p.pin.key, RunPinnedRejected); return;
      }
      announce mRunReportAttempt, p;
      if (rows[p.pin.key].profile != CodeModeReportV1 ||
          p.report.identity != p.pin.key || p.report.digest <= 0 ||
          p.report.bytes <= 0 || p.report.bytes > 17039376 ||
          p.commit == RunCommitFailed ||
          (rows[p.pin.key].outcome != 0 && rows[p.pin.key].report.bytes == 0) ||
          (rows[p.pin.key].report.bytes != 0 && rows[p.pin.key].report != p.report)) {
        fence(p.pin, RunReportFailure); reply(p.pin.key, RunCommitRejected); return;
      }
      rows[p.pin.key].report = p.report;
      announce mRunReportCommitted, (pin = p.pin, report = p.report);
      // A lost acknowledgement can follow COMMIT. It cannot synthesize the
      // missing final message or reconstruct a completed live runner on reboot.
      if (p.replyLost) { reply(p.pin.key, RunReportReplyLost); }
      else { reply(p.pin.key, RunReportStored); }
    }
    on eRunSessionCommit do (p: (key: int, outcome: int)) {
      if (!(p.key in rows) || p.outcome == 0 || rows[p.key].outcome != p.outcome) {
        reply(p.key, RunCommitRejected); return;
      }
      rows[p.key].sessionFinal = p.outcome;
      announce mRunSessionCommitted, p; reply(p.key, RunSessionStored);
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
      drained = default(set[int]); refusals = default(map[tRunPin, tPrelaunchRefusal]); admission = RunAdmitting;
      if (hasUnreleased()) { admission = RunRecoveryOnly; }
      announce mRunBoot, (incarnation = incarnation, admission = admission, rows = rows);
      reply(1, RunRebooted);
    }
    on eRunCollect do (id: int) {
      if (!(id in rows) || rows[id].custody != RunReleased) {
        announce mRunCollectionPending, id; reply(id, RunCollectionPending); return;
      }
      if (rows[id].profile == CodeModeReportV1 &&
          (rows[id].outcome == 0 || rows[id].sessionFinal != rows[id].outcome)) {
        announce mRunCollectionPending, id; reply(id, RunCollectionPending); return;
      }
      rows[id].collection = RunFrozen; rows[id].outcome = 0;
      if (rows[id].profile == CodeModeReportV1) {
        rows[id].charge = rows[id].report.bytes + 128;
      }
      announce mRunCollectionValue, (key = id, row = rows[id]);
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
  fun allowance(profile: tFinalProfile): int {
    if (profile == CodeModeReportV1) { return 17301648; }
    return 262144;
  }
  fun used(): int {
    var ids: seq[int]; var i: int; var bytes: int;
    ids = keys(rows);
    while (i < sizeof(ids)) { bytes = bytes + rows[ids[i]].charge; i = i + 1; }
    return bytes;
  }
  fun admit(p: (key: int, commit: tRunCommit), profile: tFinalProfile) {
    var pin: tRunPin;
    pin = (key = p.key, incarnation = incarnation);
    announce mRunProfileChosen, (key = p.key, profile = profile);
    // The finite fixture quota admits two full report allowances, then applies
    // the same durable charging rule after collection and owner reboot.
    if (admission != RunAdmitting || sizeof(live) == 1 || p.key in rows ||
        used() + allowance(profile) > 34603296) {
      announce mRunAdmissionRefused, pin; reply(p.key, RunRefused); return;
    }
    if (p.commit == RunCommitFailed) {
      announce mRunFreshFailed, p.key; reply(p.key, RunCommitRejected); return;
    }
    // This atomic reservation is the durable prerequisite of the spawn turn.
    rows[p.key] = (custody = RunUnreleased, collection = RunRetained, outcome = 0,
      profile = profile, allowance = allowance(profile), charge = allowance(profile),
      report = default(tSavedReport), sessionFinal = 0);
    announce mRunReserved, (pin = pin, row = rows[p.key]);
    live[p.key] = RunWaiting; reply(p.key, RunFresh);
  }
  fun final(p: tRunReport) {
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

// The real trusted renderer reaches this branch only after vetting or compile
// refusal. This actor makes that provenance an independent monitor observation;
// RunStart is the wrapper spawn, not a satellite or compiler launch witness.
machine RunPrelaunchProducer {
  start state Ready {
    on eRunProduceRefusal do (p: (owner: machine, witness: tRefusalWitness)) {
      announce mRunRefusalProduced, p.witness;
      send p.owner, eRunRefusalObserved, p.witness;
    }
  }
}
