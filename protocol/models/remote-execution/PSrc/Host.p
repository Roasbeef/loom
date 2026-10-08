// The executor's host and its ledger.
//
// This machine is `client/remote/host.gleam` over `storage/exec_ledger.gleam`.
// The ledger half (`scopeToken`, `ledger`) is durable: a crash keeps it. The
// host half (`placed`, `live`, `dead`) is the VM's memory and a crash empties
// it. One handler is one host step, and the ledger operations a step performs
// are one SQLite transaction each, so they are atomic with the checks that
// guard them (exec_ledger.gleam, "One opener").
//
// What is modelled: attach (Created and Rebound are the same here, and the
// plane build completes at once), `Run` with its admission table, the tool body
// as a Body process the scheduler finishes whenever it likes, `Query`,
// `QueryOrFence`, `Ack`, waiters and their monitors, and a crash with the
// ledger's recovery on open. What is not: see README.md.
machine Host {
  var wire: machine;
  var scopeToken: int;
  var ledger: map[tKey, tRowRec];
  var placed: bool;
  var live: map[tKey, tLive];
  var dead: set[machine];
  var nextJob: int;

  start state Up {
    entry (w: machine) {
      wire = w;
    }

    on eNet do (m: tMsg) {
      if (m.kind == K_ATTACH) {
        attach(m);
      } else if (m.kind == K_RUN) {
        admitRun(m);
      } else if (m.kind == K_ASK) {
        ask(m);
      } else if (m.kind == K_ACK) {
        ack(m.key);
      } else if (m.kind == K_CALL_DOWN) {
        callGone(m.from);
      }
    }

    on eBodyDone do (d: (key: tKey, job: int)) {
      bodyDone(d.key, d.job);
    }

    on eNoConn do {
      connectionLost();
    }

    on eCrash do {
      restart();
    }
  }

  // --- attach ---------------------------------------------------------------

  // host.attach and exec_ledger.attach: the attach token replaces whatever the
  // scope held, and the scope gets a plane. A repeat with the same token is a
  // rebind that changes nothing.
  fun attach(m: tMsg) {
    scopeToken = m.token;
    placed = true;
    reply(m, K_ATTACHED, ANS_FINISHED, LOOK_MISSING, 0);
  }

  // --- run ------------------------------------------------------------------

  // host.admit_run. A scope with no plane in this VM still answers a key the
  // ledger holds a row for (`answer_without_plane`); only a key with no row is
  // refused for the missing plane. With a plane, the ledger's own check of the
  // token comes first, then the row.
  fun admitRun(m: tMsg) {
    if (!placed) {
      if (m.key in ledger) {
        answerFromRow(m);
      } else {
        reply(m, K_ANSWER, ANS_NOPLANE, LOOK_MISSING, 0);
      }
      return;
    }
    if (m.token != scopeToken) {
      announce eStaleRun, m.key;
      reply(m, K_ANSWER, ANS_STALE, LOOK_MISSING, 0);
      return;
    }
    if (!(m.key in ledger)) {
      ledger[m.key] = (phase = ROW_ADMITTED, outcome = 0);
      startRun(m);
      return;
    }
    answerFromRow(m);
  }

  // What the host does with a `Run` for a key the ledger already holds.
  fun answerFromRow(m: tMsg) {
    var row: tRowRec;
    row = ledger[m.key];
    if (row.phase == ROW_ADMITTED) {
      if (m.key in live) {
        announce eJoined, (key = m.key, resent = m.resent);
        joinRun(m);
      } else {
        // An admitted row with no live run can only follow a failed write.
        markUnknown(m.key);
        reply(m, K_ANSWER, ANS_LOST, LOOK_MISSING, 0);
      }
    } else if (row.phase == ROW_TERMINAL) {
      if (row.outcome == fenceOutcome()) {
        announce eFoundFence, m.key;
      } else {
        announce eStoredAnswer, (key = m.key, resent = m.resent);
      }
      reply(m, K_ANSWER, ANS_FINISHED, LOOK_MISSING, row.outcome);
    } else {
      reply(m, K_ANSWER, ANS_LOST, LOOK_MISSING, 0);
    }
  }

  // host.start_run: the tool body starts as a job, and the sender is its first
  // waiter. The job number stays unique across crashes, as a weft sink is.
  fun startRun(m: tMsg) {
    nextJob = nextJob + 1;
    live[m.key] = (job = nextJob, waiters = default(seq[tWaiter]));
    announce eStart, (key = m.key, runToken = m.token, scopeToken = scopeToken);
    new Body((host = this, key = m.key, job = nextJob));
    addWaiter(m.key, m.from, m.attempt);
  }

  // host.join_run: the key is live, so the sender waits on the run that exists.
  fun joinRun(m: tMsg) {
    addWaiter(m.key, m.from, m.attempt);
  }

  // host.add_waiter. Monitoring a process that is already dead fires its DOWN
  // at once, which is how a `Run` from a killed effect process is still handled.
  fun addWaiter(key: tKey, call: machine, attempt: int) {
    var l: tLive;
    l = live[key];
    l.waiters += (sizeof(l.waiters), (proc = call, attempt = attempt));
    live[key] = l;
    if (call in dead) {
      waiterDown(key, call, false);
    }
  }

  // --- results --------------------------------------------------------------

  // host.run_finished: the row is made terminal, then every waiter is answered.
  // An outcome for a run that was cancelled meanwhile has no live entry and is
  // dropped.
  fun bodyDone(key: tKey, job: int) {
    var l: tLive;
    var w: tWaiter;
    if (!(key in live)) {
      return;
    }
    l = live[key];
    if (l.job != job) {
      return;
    }
    ledger[key] = (phase = ROW_TERMINAL, outcome = bodyOutcome(key));
    announce eTerminal, (key = key, outcome = bodyOutcome(key));
    foreach (w in l.waiters) {
      send wire, eSend, (sender = this, msg = answerTo(w, key, ANS_FINISHED, bodyOutcome(key)));
    }
    live -= (key);
  }

  // --- waiters --------------------------------------------------------------

  // host.caller_down for a process the orchestrator killed: it stops waiting on
  // every key, and a key it was the last waiter of is cancelled.
  fun callGone(call: machine) {
    var ks: seq[tKey];
    var k: tKey;
    dead += (call);
    ks = keys(live);
    foreach (k in ks) {
      waiterDown(k, call, false);
    }
  }

  // host.connection loss: every waiter is down with `noconnection`.
  fun connectionLost() {
    var ks: seq[tKey];
    var k: tKey;
    var l: tLive;
    var w: tWaiter;
    var ws: seq[tWaiter];
    ks = keys(live);
    foreach (k in ks) {
      l = live[k];
      ws = l.waiters;
      foreach (w in ws) {
        waiterDown(k, w.proc, true);
      }
    }
  }

  // host.waiter_gone: the waiter is dropped whatever the reason, and the reason
  // decides whether a key left with no waiter is cancelled.
  fun waiterDown(key: tKey, call: machine, noconn: bool) {
    var l: tLive;
    var rest: seq[tWaiter];
    var w: tWaiter;
    if (!(key in live)) {
      return;
    }
    l = live[key];
    if (!isWaiter(l.waiters, call)) {
      return;
    }
    foreach (w in l.waiters) {
      if (w.proc != call) {
        rest += (sizeof(rest), w);
      }
    }
    l.waiters = rest;
    live[key] = l;
    if (sizeof(rest) == 0 && cancelsRun(noconn)) {
      cancelRun(key, noconn);
    }
  }

  fun isWaiter(waiters: seq[tWaiter], call: machine): bool {
    var w: tWaiter;
    foreach (w in waiters) {
      if (w.proc == call) {
        return true;
      }
    }
    return false;
  }

  // host.cancels_run: only an exit that is not `noconnection` stops the call.
  fun cancelsRun(noconn: bool): bool {
    return !noconn;
  }

  // host.cancel_run: the row becomes unknown first, then the worker is killed
  // (the live entry goes, so the body's late result is dropped).
  fun cancelRun(key: tKey, noconn: bool) {
    markUnknown(key);
    live -= (key);
    announce eCancelled, (key = key, noconn = noconn);
  }

  // exec_ledger.mark_unknown, which settles only an admitted row.
  fun markUnknown(key: tKey) {
    var row: tRowRec;
    if (!(key in ledger)) {
      return;
    }
    row = ledger[key];
    if (row.phase == ROW_ADMITTED) {
      ledger[key] = (phase = ROW_UNKNOWN, outcome = 0);
      announce eUnknown, key;
    }
  }

  // --- queries --------------------------------------------------------------

  // host.lookup and host.fenced_lookup. A key with a row is reported as the row
  // stands. A key with none is a missing row for `Query`; for `QueryOrFence` the
  // ledger stores "did not start" in the same transaction, so a `Run` for the
  // key that is still in flight finds it taken.
  fun ask(m: tMsg) {
    var row: tRowRec;
    if (m.key in ledger) {
      row = ledger[m.key];
      if (row.phase == ROW_ADMITTED) {
        reply(m, K_LOOKUP, ANS_FINISHED, LOOK_ADMITTED, 0);
      } else if (row.phase == ROW_TERMINAL) {
        reply(m, K_LOOKUP, ANS_FINISHED, LOOK_TERMINAL, row.outcome);
      } else {
        reply(m, K_LOOKUP, ANS_FINISHED, LOOK_UNKNOWN, 0);
      }
    } else if (m.fence) {
      ledger[m.key] = (phase = ROW_TERMINAL, outcome = fenceOutcome());
      announce eFenced, m.key;
      announce eTerminal, (key = m.key, outcome = fenceOutcome());
      reply(m, K_LOOKUP, ANS_FINISHED, LOOK_FENCED, 0);
    } else {
      reply(m, K_LOOKUP, ANS_FINISHED, LOOK_MISSING, 0);
    }
  }

  // exec_ledger.ack: a settled row is deleted, an admitted one is untouched.
  fun ack(key: tKey) {
    var row: tRowRec;
    if (!(key in ledger)) {
      return;
    }
    row = ledger[key];
    if (row.phase != ROW_ADMITTED) {
      ledger -= (key);
      announce eAcked, key;
    }
  }

  // --- the VM ---------------------------------------------------------------

  // exec_ledger.open on a new VM: every run the old VM had admitted is lost, so
  // its row becomes unknown, and nothing is relaunched. The host's memory is
  // empty, so no scope has a plane until the next attach.
  fun restart() {
    var ks: seq[tKey];
    var k: tKey;
    ks = keys(ledger);
    foreach (k in ks) {
      markUnknown(k);
    }
    placed = false;
    live = default(map[tKey, tLive]);
    dead = default(set[machine]);
  }

  // --- replies --------------------------------------------------------------

  fun reply(m: tMsg, kind: tKind, answer: tAnswer, look: tLook, outcome: int) {
    var r: tMsg;
    r = default(tMsg);
    r.kind = kind;
    r.dest = m.from;
    r.from = this;
    r.key = m.key;
    r.attempt = m.attempt;
    r.answer = answer;
    r.look = look;
    r.outcome = outcome;
    send wire, eSend, (sender = this, msg = r);
  }

  fun answerTo(waiter: tWaiter, key: tKey, answer: tAnswer, outcome: int): tMsg {
    var r: tMsg;
    r = default(tMsg);
    r.kind = K_ANSWER;
    r.dest = waiter.proc;
    r.attempt = waiter.attempt;
    r.from = this;
    r.key = key;
    r.answer = answer;
    r.outcome = outcome;
    return r;
  }
}

// The tool body. It ends when the scheduler gets to it, which is any time after
// it started, and it tells the host once. The host ignores the news when the
// run was cancelled or the VM restarted meanwhile.
machine Body {
  start state Running {
    entry (p: (host: machine, key: tKey, job: int)) {
      send p.host, eBodyDone, (key = p.key, job = p.job);
    }
  }
}
