// The network between the orchestrator and the executor.
//
// Erlang orders messages only per sender and receiver pair, so the wire keeps
// one queue per pair and delivers the head of any non-empty queue it likes at
// each step. A request from one effect process can therefore arrive after a
// later request from another, and a dead open's `Run` can arrive after the
// next open's `Attach`. That is the freedom `surface.gleam` and
// `exec_ledger.gleam` rely on the attach token and the key fence to tame.
//
// A broken connection loses every message in flight in both directions and
// tells each process that was waiting on the executor, which is the
// `noconnection` DOWN of the monitor `surface.send_and_wait` takes before it
// sends, and which `address.watch` stands for. A process is "watching" from
// the moment it hands the wire a request until the wire delivers the reply.
// A message sent after the break travels normally: Erlang reconnects on the
// next send.
//
// A crash of the executor's VM is a break that also restarts the host. The
// `eCrash` is sent in the wire's own order to the host, so messages delivered
// before it were handled by the old VM and later ones by the new.
machine Wire {
  var host: machine;
  var queues: map[(machine, machine), seq[tMsg]];
  var watching: map[machine, int];
  var stepPending: bool;
  var lazy: seq[tSubmit];

  start state Up {
    on eWireHost do (h: machine) {
      host = h;
    }

    on eSend do (s: tSubmit) {
      enqueue(s);
      schedule();
    }

    on eLazySend do (s: tSubmit) {
      lazy += (sizeof(lazy), s);
      schedule();
    }

    on eStep do {
      stepPending = false;
      deliverOne();
      schedule();
    }

    on eBreak do {
      sever();
      send host, eNoConn;
      notifyWatchers();
    }

    on eCrashHost do {
      sever();
      send host, eCrash;
      notifyWatchers();
    }
  }

  // Queues a message behind the earlier ones of the same sender and receiver.
  // A request that expects a reply puts its sender on watch.
  fun enqueue(s: tSubmit) {
    var pair: (machine, machine);
    var q: seq[tMsg];
    pair = (s.sender, s.msg.dest);
    if (pair in queues) {
      q = queues[pair];
    }
    q += (sizeof(q), s.msg);
    queues[pair] = q;
    if (s.msg.kind == K_RUN || s.msg.kind == K_START || s.msg.kind == K_ASK || s.msg.kind == K_ATTACH) {
      watching[s.sender] = s.msg.attempt;
    }
  }

  // Delivers the head of one non-empty queue, chosen by the scheduler.
  fun deliverOne() {
    var pairs: seq[(machine, machine)];
    var ready: seq[(machine, machine)];
    var pair: (machine, machine);
    var q: seq[tMsg];
    var m: tMsg;
    pairs = keys(queues);
    foreach (pair in pairs) {
      if (sizeof(queues[pair]) > 0) {
        ready += (sizeof(ready), pair);
      }
    }
    if (sizeof(ready) == 0) {
      return;
    }
    pair = choose(ready);
    q = queues[pair];
    m = q[0];
    q -= (0);
    queues[pair] = q;
    if (m.kind == K_ANSWER || m.kind == K_LOOKUP || m.kind == K_ATTACHED) {
      if (m.dest in watching) {
        if (watching[m.dest] == m.attempt) {
          watching -= (m.dest);
        }
      }
    }
    send m.dest, eNet, m;
  }

  // Keeps exactly one delivery step scheduled while anything is in flight. When
  // nothing is, the held acknowledgements go out.
  fun schedule() {
    var pairs: seq[(machine, machine)];
    var pair: (machine, machine);
    var busy: bool;
    var held: seq[tSubmit];
    var s: tSubmit;
    pairs = keys(queues);
    foreach (pair in pairs) {
      if (sizeof(queues[pair]) > 0) {
        busy = true;
      }
    }
    if (busy) {
      if (!stepPending) {
        stepPending = true;
        send this, eStep;
      }
      return;
    }
    if (sizeof(lazy) > 0) {
      held = lazy;
      lazy = default(seq[tSubmit]);
      foreach (s in held) {
        enqueue(s);
      }
      schedule();
    }
  }

  // Every message in flight is lost.
  fun sever() {
    queues = default(map[(machine, machine), seq[tMsg]]);
  }

  // Every process waiting on the executor hears `noconnection` once.
  fun notifyWatchers() {
    var w: machine;
    var ws: seq[machine];
    ws = keys(watching);
    foreach (w in ws) {
      send w, eNoConn;
    }
    watching = default(map[machine, int]);
  }
}
