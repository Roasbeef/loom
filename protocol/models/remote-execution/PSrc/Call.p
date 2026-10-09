// One effect process on the orchestrator: `surface.run` for a fresh call, or
// `surface.recover` for an orphaned one.
//
// A fresh call sends `Run` and waits. Whenever the connection drops it sends
// the same `Run` again (`surface.send_and_wait` reports `HostDown`, the loop
// reconnects, and `attempt` repeats the exchange). An orphaned call asks the
// ledger what became of it first, with `QueryOrFence` when its replay policy is
// `ReplayNever` and a plain `Query` when it is `ReplaySafe` (`surface.recover`):
//
// | The ledger says | A ReplaySafe call | A ReplayNever call |
// | --- | --- | --- |
// | no row | the planner replays it: `Run` | (the fence stored one) |
// | fenced | | staged as "did not run" |
// | terminal | staged as that outcome | staged as that outcome |
// | unknown | staged as unknown | staged as unknown |
// | admitted | `Run` again, to join it | `Run` again, to join it |
//
// The process settles exactly once by telling its Orch, and is then done. The
// Orch kills it when its open or runtime ends.
machine Call {
  var wire: machine;
  var executor: machine;
  var orch: machine;
  var gen: int;
  var key: tKey;
  var replay: tReplay;
  var token: int;
  var attempt: int;
  var joining: bool;
  var resent: bool;

  start state Begin {
    entry (p: (wire: machine, executor: machine, orch: machine, gen: int, key: tKey, replay: tReplay, token: int, mode: tMode)) {
      wire = p.wire;
      executor = p.executor;
      orch = p.orch;
      gen = p.gen;
      key = p.key;
      replay = p.replay;
      token = p.token;
      if (p.mode == MODE_RUN) {
        sendRun();
        goto Running;
      } else {
        sendAsk();
        goto Asking;
      }
    }
  }

  // Waiting for the `Run`'s answer.
  state Running {
    on eNet do (m: tMsg) {
      if (m.kind == K_ANSWER && m.attempt == attempt) {
        answered(m);
      }
    }

    on eNoConn do {
      resent = true;
      sendRun();
      resent = false;
    }
  }

  // Waiting for the ledger's answer to a recovery query.
  state Asking {
    on eNet do (m: tMsg) {
      if (m.kind == K_LOOKUP && m.attempt == attempt) {
        looked(m);
      }
    }

    on eNoConn do {
      resent = true;
      sendAsk();
      resent = false;
    }
  }

  state Done {
    ignore eNet, eNoConn;
  }

  // surface.run, and the Ok(RunFinished | RunLost | RunRefused) arms of
  // `await_live`, which reads only a finished outcome and calls anything else
  // an unknown one.
  fun answered(m: tMsg) {
    if (m.answer == ANS_FINISHED) {
      settle(D_FINISHED, m.outcome);
    } else if (joining) {
      settle(D_LOST, 0);
    } else if (m.answer == ANS_LOST) {
      settle(D_LOST, 0);
    } else if (m.answer == ANS_STALE) {
      settle(D_STALE, 0);
    } else {
      settle(D_NOPLANE, 0);
    }
  }

  // surface.recover.
  fun looked(m: tMsg) {
    if (m.look == LOOK_TERMINAL) {
      settle(D_FINISHED, m.outcome);
    } else if (m.look == LOOK_UNKNOWN) {
      settle(D_LOST, 0);
    } else if (m.look == LOOK_ADMITTED) {
      joining = true;
      sendRun();
      goto Running;
    } else if (replay == REPLAY_SAFE) {
      // NotStarted for a call the planner may replay: it runs again, now.
      sendRun();
      goto Running;
    } else {
      announce eReportedNotStarted, key;
      settle(D_NOT_RUN, 0);
    }
  }

  fun settle(kind: tDelivery, outcome: int) {
    send orch, eCallDone, (gen = gen, key = key, kind = kind, outcome = outcome);
    goto Done;
  }

  fun sendRun() {
    var m: tMsg;
    attempt = attempt + 1;
    m = default(tMsg);
    m.kind = K_RUN;
    m.dest = executor;
    m.from = this;
    m.key = key;
    m.token = token;
    m.attempt = attempt;
    m.resent = resent;
    send wire, eSend, (sender = this, msg = m);
  }

  fun sendAsk() {
    var m: tMsg;
    attempt = attempt + 1;
    m = default(tMsg);
    m.attempt = attempt;
    m.kind = K_ASK;
    m.dest = executor;
    m.from = this;
    m.key = key;
    m.fence = replay == REPLAY_NEVER;
    send wire, eSend, (sender = this, msg = m);
  }
}
