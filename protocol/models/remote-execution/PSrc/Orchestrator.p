// The orchestrator's side of one session: its durable intents and results, the
// open that attaches, and the effect processes it runs.
//
// The Orch stands for `remote/workspace` and the runtime above it. Its durable
// store survives everything the environment does to it: a set of call keys with
// their replay policies, written before any `Run` is sent, and the set of keys
// whose outcome it has staged. An *open* is the process state on top of that
// store, and `eOpenCrash` ends it. The next open mints a new attach token,
// attaches once, and recovers every key that has no staged outcome. An
// `eRuntimeRestart` ends only the runtime: its effect processes die and are
// recovered, but the open and its token stay (`surface.gleam` shares one token
// across every runtime restart inside an open).
//
// Staging an outcome and acknowledging it to the executor are one step here.
// The reconciler that re-sends a lost acknowledgement is not modelled (it only
// affects how long a settled row stays).
machine Orch {
  var wire: machine;
  var executor: machine;
  var replays: seq[tReplay];
  var acks: tAck;
  var gen: int;
  var token: int;
  var attachAttempt: int;
  var delivered: set[tKey];
  var calls: seq[machine];
  // The session's execution service, told when an open attaches and ends.
  // Null in the cases that model tool calls alone.
  var record: machine;

  start state Init {
    entry (p: (wire: machine, executor: machine, replays: seq[tReplay], acks: tAck, record: machine)) {
      var i: int;
      wire = p.wire;
      executor = p.executor;
      replays = p.replays;
      acks = p.acks;
      record = p.record;
      i = 0;
      while (i < sizeof(replays)) {
        announce eIntent, i;
        i = i + 1;
      }
      gen = 1;
      token = 1;
      sendAttach();
      goto Attaching;
    }
  }

  // The open has sent its `Attach` and has not heard back. An open attaches
  // once, before its first call (`surface.attach`), so the environment cannot
  // end it in this state, and a dropped connection sends the same `Attach`
  // again.
  state Attaching {
    defer eOpenCrash, eRuntimeRestart;
    ignore eCallDone;

    on eNet do (m: tMsg) {
      if (m.kind == K_ATTACHED && m.attempt == attachAttempt) {
        startCalls();
        if (record != null) {
          send record, eOpenReady, token;
        }
        goto Running;
      }
    }

    on eNoConn do {
      sendAttach();
    }
  }

  state Running {
    on eCallDone do (d: (gen: int, key: tKey, kind: tDelivery, outcome: int)) {
      stage(d.gen, d.key, d.kind, d.outcome);
    }

    // The process died with its open: its effect processes die, the host's
    // monitors of them fire, and the next open attaches with a new token.
    on eOpenCrash do {
      killCalls();
      if (record != null) {
        send record, eOpenGone;
      }
      gen = gen + 1;
      token = token + 1;
      sendAttach();
      goto Attaching;
    }

    // The runtime restarted inside the open: the same token, a recovery for
    // every call without an outcome.
    on eRuntimeRestart do {
      killCalls();
      gen = gen + 1;
      startCalls();
    }

    ignore eNoConn, eNet;
  }

  // The orchestrator stages an outcome at most once per key, and acknowledges it
  // to the executor only after staging. An outcome from an earlier open's
  // effect process died with that open.
  fun stage(callGen: int, key: tKey, kind: tDelivery, outcome: int) {
    var m: tMsg;
    if (callGen != gen || key in delivered) {
      return;
    }
    delivered += (key);
    announce eDelivered, (key = key, kind = kind, outcome = outcome);
    m = default(tMsg);
    m.kind = K_ACK;
    m.dest = executor;
    m.from = this;
    m.key = key;
    if (acks == ACK_AT_ONCE) {
      send wire, eSend, (sender = this, msg = m);
    } else {
      send wire, eLazySend, (sender = this, msg = m);
    }
  }

  // The first open runs every call. A later open, or a restarted runtime,
  // recovers each call that has no staged outcome.
  fun startCalls() {
    var k: tKey;
    var mode: tMode;
    var c: machine;
    calls = default(seq[machine]);
    k = 0;
    while (k < sizeof(replays)) {
      if (!(k in delivered)) {
        mode = MODE_RECOVER;
        if (gen == 1) {
          mode = MODE_RUN;
        }
        c = new Call((wire = wire, executor = executor, orch = this, gen = gen, key = k, replay = replays[k], token = token, mode = mode));
        calls += (sizeof(calls), c);
      }
      k = k + 1;
    }
  }

  // The effect processes die, and the host's monitors of them fire with a
  // reason other than `noconnection`.
  fun killCalls() {
    var c: machine;
    var m: tMsg;
    foreach (c in calls) {
      send c, halt;
      m = default(tMsg);
      m.kind = K_CALL_DOWN;
      m.dest = executor;
      m.from = c;
      send wire, eSend, (sender = this, msg = m);
    }
    calls = default(seq[machine]);
  }

  // surface.attach: a token minted for this open.
  fun sendAttach() {
    var m: tMsg;
    attachAttempt = attachAttempt + 1;
    m = default(tMsg);
    m.attempt = attachAttempt;
    m.kind = K_ATTACH;
    m.dest = executor;
    m.from = this;
    m.token = token;
    send wire, eSend, (sender = this, msg = m);
  }
}
