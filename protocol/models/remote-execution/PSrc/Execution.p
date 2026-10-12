// Background executions on the orchestrator's side (protocol-change/078, the
// addendum on background code mode).
//
// Record stands for `client/async_runs` with `async_codemode.remote` and the
// owner port's reconciler: the durable execution records, the worker that
// waits on each program, recovery after the orchestrator restarts, and the
// reconciler pass that stops orphans and acknowledges settled rows. Exec is one
// worker: `surface.start_execution`, which sends `StartExecution` and sends it
// again after a dropped connection until it hears how the start ended.
//
// A record's phase is durable and decides everything. A decision to close it
// (a cancel, the deadline, a restart) is made first and the stop is sent
// after, so a stop that a partition loses is found again by the reconciler.

// A record's phase: starting or running, finished, or lost.
enum tPhase { P_LIVE, P_FINISHED, P_LOST }

machine Record {
  var wire: machine;
  var executor: machine;
  var owned: seq[tKey];
  var phase: map[tKey, tPhase];
  var workers: map[tKey, machine];
  var token: int;
  var gen: int;
  var asking: set[tKey];
  var attempt: int;
  var launched: bool;
  var recovering: bool;

  // Nothing is launched until the first open attaches, and the environment's
  // cancels, deadline and last reconcile wait for the launch.
  start state Idle {
    entry (p: (wire: machine, executor: machine, owned: seq[tKey])) {
      wire = p.wire;
      executor = p.executor;
      owned = p.owned;
    }

    defer eExecCancel, eDeadline, eReconcile;

    on eOpenReady do (t: int) {
      token = t;
      gen = gen + 1;
      launched = true;
      launch();
      goto Serving;
    }
  }

  state Serving {
    // The open attached again after the orchestrator restarted: the records a
    // restarted service found live are recovered.
    on eOpenReady do (t: int) {
      token = t;
      gen = gen + 1;
      if (recovering) {
        recovering = false;
        recover();
      }
    }

    // The orchestrator's VM went away with the open: every worker dies, and the
    // host's monitor of it fires with `noconnection`, which never cancels. The
    // records stay; the next open recovers them.
    on eOpenGone do {
      var k: tKey;
      var ks: seq[tKey];
      ks = keys(workers);
      foreach (k in ks) {
        loseWorker(k);
      }
      recovering = true;
    }

    on eExecDone do (d: (gen: int, key: tKey, answer: tAnswer, outcome: int)) {
      heard(d.gen, d.key, d.answer, d.outcome);
    }

    on eExecCancel do {
      var live: seq[tKey];
      var k: tKey;
      foreach (k in owned) {
        if (k in phase && phase[k] == P_LIVE) {
          live += (sizeof(live), k);
        }
      }
      if (sizeof(live) > 0) {
        decideLost(choose(live));
      }
    }

    on eDeadline do {
      var k: tKey;
      foreach (k in owned) {
        if (k in phase && phase[k] == P_LIVE) {
          decideLost(k);
        }
      }
    }

    // The reconciler's pass, held by the wire until nothing is in flight, so a
    // start that a dead worker sent has arrived or is gone.
    on eReconcile do {
      var m: tMsg;
      m = default(tMsg);
      m.kind = K_LIST;
      m.dest = executor;
      m.from = this;
      send wire, eLazySend, (sender = this, msg = m);
    }

    on eNet do (m: tMsg) {
      if (m.kind == K_LISTED) {
        reconcile(m.running, m.settled);
      } else if (m.kind == K_LOOKUP && m.key in asking) {
        asking -= (m.key);
        recovered(m.key, m.look, m.outcome);
      }
    }

    // A recovery question that the network lost has no answer, and the record
    // is lost, as `surface.query` gives up after its bound.
    on eNoConn do {
      var k: tKey;
      var ks: seq[tKey];
      ks = default(seq[tKey]);
      foreach (k in asking) {
        ks += (sizeof(ks), k);
      }
      asking = default(set[tKey]);
      foreach (k in ks) {
        decideLost(k);
      }
    }
  }

  // async_codemode.launch_remote: the record is claimed before its worker
  // starts.
  fun launch() {
    var k: tKey;
    foreach (k in owned) {
      phase[k] = P_LIVE;
      announce eExecCreated, k;
      workers[k] = new Exec((wire = wire, executor = executor, record = this, gen = gen, key = k, token = token));
    }
  }

  // async_runs.recover over the executor's ledger: a live record's key is
  // asked about once; a stored value finishes it, and anything else loses it.
  fun recover() {
    var k: tKey;
    var m: tMsg;
    foreach (k in owned) {
      if (k in phase && phase[k] == P_LIVE) {
        attempt = attempt + 1;
        asking += (k);
        m = default(tMsg);
        m.kind = K_ASK;
        m.dest = executor;
        m.from = this;
        m.key = k;
        m.attempt = attempt;
        m.fence = false;
        send wire, eSend, (sender = this, msg = m);
      }
    }
  }

  fun recovered(key: tKey, look: tLook, outcome: int) {
    if (phase[key] != P_LIVE) {
      return;
    }
    if (look == LOOK_TERMINAL) {
      announce eExecRecovered, key;
      finish(key, outcome);
    } else {
      decideLost(key);
    }
  }

  // What a worker heard. Only a live record changes: the first terminal phase
  // the service settles on stands.
  fun heard(workerGen: int, key: tKey, answer: tAnswer, outcome: int) {
    if (workerGen != gen || phase[key] != P_LIVE) {
      return;
    }
    if (key in workers) {
      workers -= (key);
    }
    if (answer == ANS_FINISHED) {
      finish(key, outcome);
    } else {
      phase[key] = P_LOST;
      announce eRecordLost, (key = key, decided = false);
    }
  }

  fun finish(key: tKey, outcome: int) {
    phase[key] = P_FINISHED;
    announce eRecordFinished, (key = key, outcome = outcome);
  }

  // async_runs.close: the decision is durable first, then the worker is killed
  // (a DOWN that is not `noconnection`) and the stop is sent.
  fun decideLost(key: tKey) {
    var m: tMsg;
    if (phase[key] != P_LIVE) {
      return;
    }
    phase[key] = P_LOST;
    announce eStopDecided, key;
    announce eRecordLost, (key = key, decided = true);
    if (key in workers) {
      send workers[key], halt;
      m = default(tMsg);
      m.kind = K_CALL_DOWN;
      m.dest = executor;
      m.from = workers[key];
      send wire, eSend, (sender = this, msg = m);
      workers -= (key);
    }
    sendStop(key);
  }

  fun loseWorker(key: tKey) {
    var m: tMsg;
    send workers[key], halt;
    m = default(tMsg);
    m.kind = K_CALL_LOST;
    m.dest = executor;
    m.from = workers[key];
    send wire, eSend, (sender = this, msg = m);
    workers -= (key);
  }

  fun sendStop(key: tKey) {
    var m: tMsg;
    m = default(tMsg);
    m.kind = K_STOP;
    m.dest = executor;
    m.from = this;
    m.key = key;
    send wire, eSend, (sender = this, msg = m);
  }

  // owner_port.acknowledge_settled for executions: a running program whose
  // record is not live is stopped again, and a settled row is acknowledged
  // only once its record is closed (`workspace.settled_by_kind`).
  fun reconcile(running: seq[tKey], settled: seq[tKey]) {
    var k: tKey;
    var m: tMsg;
    foreach (k in running) {
      if (k in phase && phase[k] != P_LIVE) {
        sendStop(k);
      }
    }
    foreach (k in settled) {
      if (closed(k)) {
        announce eExecAckSent, k;
        m = default(tMsg);
        m.kind = K_ACK;
        m.dest = executor;
        m.from = this;
        m.key = k;
        send wire, eSend, (sender = this, msg = m);
      }
    }
  }

  fun closed(key: tKey): bool {
    return !(key in phase) || phase[key] != P_LIVE;
  }
}

// One worker: it sends `StartExecution` and waits, sends the same start again
// after a dropped connection, and tells its record how the start ended.
machine Exec {
  var wire: machine;
  var executor: machine;
  var record: machine;
  var gen: int;
  var key: tKey;
  var token: int;
  var attempt: int;
  var resent: bool;

  start state Waiting {
    entry (p: (wire: machine, executor: machine, record: machine, gen: int, key: tKey, token: int)) {
      wire = p.wire;
      executor = p.executor;
      record = p.record;
      gen = p.gen;
      key = p.key;
      token = p.token;
      sendStart();
    }

    on eNet do (m: tMsg) {
      if (m.kind == K_ANSWER && m.attempt == attempt) {
        send record, eExecDone, (gen = gen, key = key, answer = m.answer, outcome = m.outcome);
        goto Done;
      }
    }

    on eNoConn do {
      resent = true;
      sendStart();
      resent = false;
    }
  }

  state Done {
    ignore eNet, eNoConn;
  }

  fun sendStart() {
    var m: tMsg;
    attempt = attempt + 1;
    m = default(tMsg);
    m.kind = K_START;
    m.dest = executor;
    m.from = this;
    m.key = key;
    m.token = token;
    m.attempt = attempt;
    m.resent = resent;
    send wire, eSend, (sender = this, msg = m);
  }
}
