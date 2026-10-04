// This actor owns the abstract durable ledger. Rows, launch intent, receipt
// and epoch fence survive eCrash; the queued launch permission does not.
// Row capacity reserves terminal evidence even when the owner is absent.
machine Executor {
  var driver: machine;
  var owner: machine;
  var helper: machine;
  var mode: tMode;
  var boot: int;
  var epoch: tEpoch;
  var closed: bool;
  var rows: map[tKey, tRow];
  var route: map[tKey, tWire];
  var terminalPayloads: map[tKey, tTerminalPayload];

  start state Init {
    entry (p: tSetup) {
      driver = p.driver;
      mode = p.mode;
      boot = 1;
      epoch = (session = 1, workspace = 1);
      goto Ready;
    }
  }

  state Ready {
    on eConnect do (p: (owner: machine, helper: machine)) {
      owner = p.owner;
      helper = p.helper;
    }
    on eAdmit do (p: tWire) { admit(p); }
    on eReconcile do (p: tWire) { reconcile(p); }
    on eLaunch do (p: tNative) {
      if (closed || p.boot != boot || !(p.key in rows) || rows[p.key].phase != Admitted) {
        return;
      }
      // The durable intent is irrevocable: no retry resets it to Admitted.
      rows[p.key].phase = Intent;
      rows[p.key].launchBoot = boot;
      announce mIntent, p;
      if (mode == CrashBeforeStart) {
        recover();
        reply(route[p.key], Prior);
        return;
      }
      send helper, eStartNative, p;
      if (mode == CrashAfterSend) {
        recover();
        reply(route[p.key], Prior);
      }
    }
    on eStartedNative do (p: tNative) {
      if (matches(p) && rows[p.key].phase == Intent) {
        rows[p.key].phase = Running;
        notify(p.key);
      }
    }
    on eTerminalNative do (result: (native: tNative, outcome: tOutcome)) {
      var payload: tTerminalPayload;
      if (matches(result.native) && rows[result.native.key].phase != Terminal) {
        payload = (request = rows[result.native.key].request, native = result.native,
          digest = 3, outcome = result.outcome);
        if (!(result.native.key in terminalPayloads)) {
          terminalPayloads[result.native.key] = payload;
          announce mNativePayloadRetained, payload;
        }
        // A duplicate cannot replace the durable payload, including after reboot.
        if (terminalPayloads[result.native.key] != payload) { return; }
        if (mode == TerminalCommitPaused) { send driver, eNativePayloadView, payload; }
        else { send this, eCommitNativeTerminal, result.native; }
      }
    }
    on eCommitNativeTerminal do (n: tNative) {
      if (matches(n) && n.key in terminalPayloads && rows[n.key].phase != Terminal) {
        rows[n.key].phase = Terminal;
        rows[n.key].outcome = terminalPayloads[n.key].outcome;
        rows[n.key].terminalDigest = terminalPayloads[n.key].digest;
        announce mTerminal, n.key;
        announce mNativeTerminalCommitted, terminalPayloads[n.key];
        notify(n.key);
      }
    }
    on eRetiredNative do (p: tNative) {
      if (matches(p) && !rows[p.key].retired) {
        rows[p.key].retired = true;
        announce mRetired, p.key;
        notify(p.key);
      }
    }
    on eCancel do (p: tWire) {
      if (p.request.key in rows && rows[p.request.key].request == p.request) {
        if (rows[p.request.key].phase == Intent || rows[p.request.key].phase == Running) {
          send helper, eCancelNative,
            (key = p.request.key, boot = rows[p.request.key].launchBoot);
        }
        reply(p, Prior);
      }
    }
    on eReceipt do (p: tWire) {
      if (p.request.key in rows && rows[p.request.key].request == p.request &&
          rows[p.request.key].phase == Terminal) {
        rows[p.request.key].receipt = true;
        announce mReceipt, p.request;
        reply(p, Prior);
      }
    }
    on eCrash do {
      recover();
      send driver, eControlDone;
    }
    on eCloseEpoch do {
      // Closure is durable even with live rows. Only new IDs are refused.
      closed = true;
      announce mClose, epoch;
      send driver, eControlDone;
    }
    on eCollect do (k: tKey) {
      if (k in rows && closed && rowSafe(rows[k])) {
        collect(k);
      }
      send driver, eControlDone;
    }
    on eAdvanceEpoch do {
      var ks: seq[tKey];
      var i: int;
      var allSafe: bool;
      ks = keys(rows);
      allSafe = closed;
      i = 0;
      while (i < sizeof(ks)) {
        allSafe = allSafe && rowSafe(rows[ks[i]]);
        i = i + 1;
      }
      // This bounded model advances once. The high-water mark, unlike rows,
      // is never deleted, including across another executor reboot.
      if (allSafe && epoch.session == 1) {
        i = 0;
        while (i < sizeof(ks)) {
          collect(ks[i]);
          i = i + 1;
        }
        epoch = (session = 2, workspace = 2);
        closed = false;
        announce mAdvance, epoch;
        announce mWitness, Advance;
      }
      send driver, eControlDone;
    }
  }

  fun admit(p: tWire) {
    var k: tKey;
    k = p.request.key;
    // Identity lookup precedes closure: same-ID reconciliation remains
    // available while a closed epoch drains, without allocating a row.
    if (k in rows) {
      if (rows[k].request.digest != p.request.digest) {
        reply(p, Conflict);
      } else {
        route[k] = p;
        reply(p, Prior);
        if (closed) { announce mWitness, ClosedReconcile; }
      }
      return;
    }
    if (closed || k.sessionEpoch != epoch.session || k.workspaceEpoch != epoch.workspace ||
        k.session != 1 || k.workspace != 1 || k.executor != 1) {
      reply(p, Fenced);
      return;
    }
    if (sizeof(rows) == 2) {
      reply(p, Capacity);
      announce mWitness, Pressure;
      return;
    }
    rows[k] = (request = p.request, phase = Admitted, launchBoot = 0,
               retired = false, receipt = false, outcome = NoOutcome, terminalDigest = 0);
    route[k] = p;
    announce mAdmit, p.request;
    reply(p, Prior);
    send this, eLaunch, (key = k, boot = boot);
  }

  fun reconcile(p: tWire) {
    if (p.request.key in rows) {
      if (rows[p.request.key].request == p.request) {
        route[p.request.key] = p;
        reply(p, Prior);
      } else {
        reply(p, Conflict);
      }
    } else {
      reply(p, Missing);
    }
  }

  fun reply(p: tWire, answer: tAnswer) {
    var r: tReply;
    r = (request = p.request, answer = answer, row = default(tRow),
         connection = p.connection, boot = boot);
    if (answer == Prior) {
      r.row = rows[p.request.key];
      announce mAck, p.request;
    }
    announce mAnswer, r;
    if (answer == Conflict) { announce mWitness, ConflictSeen; }
    if (answer == Fenced && p.request.key.sessionEpoch == 1) {
      announce mWitness, OldFence;
    }
    if (mode == Lossy && choose()) {
      announce mWitness, LostTransport;
      if (answer == Prior && r.row.phase == Admitted) { announce mWitness, AdmissionAckLost; }
      if (answer == Prior && r.row.phase == Terminal) { announce mWitness, ResultLost; }
    } else {
      send p.owner, eReply, r;
    }
  }

  fun notify(k: tKey) {
    if (k in route) { reply(route[k], Prior); }
  }

  fun matches(p: tNative): bool {
    return p.key in rows && rows[p.key].launchBoot == p.boot && rows[p.key].phase != Admitted;
  }

  fun recover() {
    boot = boot + 1;
    announce mRecovered, (boot = boot, rows = rows);
    // Volatile routes are connection hints. We preserve them in this model
    // solely to publish a recovery view; they grant no launch permission.
  }

  fun collect(k: tKey) {
    announce mGC, k;
    rows -= (k);
    route -= (k);
    terminalPayloads -= (k);
  }
}
