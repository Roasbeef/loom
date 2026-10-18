// The network between the laptop and the remote orchestrator.
//
// Erlang orders messages only per sender and receiver pair, so the wire keeps
// one queue per pair and delivers the head of any non-empty queue at each step.
// A `Spawn` from a killed effect process, a `Spawn` the drainer resent and a
// `RunEnded` from the environment therefore reach the remote in any order
// across senders. That is the freedom the adoption check and the ended fence are
// written against.
//
// A broken connection loses every message in flight in both directions and
// tells each effect process that is waiting on the remote once, which is the
// `Unreachable` that `remote_spawn` resends on. A process waits from the moment
// it registers with `eWatch` until it unregisters. A message sent after the
// break travels normally, because Erlang reconnects on the next send. A crash of
// the remote's VM is a break that also restarts the port.
//
// The connection is up or down. A send from the laptop dials, so it brings the
// connection up. The remote never dials: a message it originates (`eSendUp`) is
// sent only while the connection is up, and is not produced at all while it is
// down, which is the drainer's pass skipping the laptop without a connect
// attempt. A break takes the connection down. The link keeper brings it back, and
// the model assumes it does so eventually (`eReconnect`, which the environment
// sends before the run ends): the fair reconnection the keeper's liveness rests
// on. A reconnection rings the remote's drainer, which ticks every few seconds
// while a row is owed.
machine Wire {
  var port: machine;
  var queues: map[(machine, machine), seq[tMsg]];
  var watching: set[machine];
  var stepPending: bool;
  var connected: bool;

  start state Up {
    on eWirePort do (p: machine) {
      port = p;
    }

    on eWatch do (m: machine) {
      watching += (m);
    }

    on eUnwatch do (m: machine) {
      watching -= (m);
    }

    on eSend do (s: tSubmit) {
      connected = true;
      enqueue(s);
      schedule();
    }

    on eSendUp do (s: tSubmit) {
      if (connected) {
        enqueue(s);
        schedule();
      }
    }

    on eReconnect do {
      connected = true;
      send port, eMailPass;
    }

    on eStep do {
      stepPending = false;
      deliverOne();
      schedule();
    }

    on eBreak do {
      connected = false;
      sever();
      notifyWatchers();
    }

    on eCrashRemote do {
      connected = false;
      sever();
      send port, eRestart;
      notifyWatchers();
    }
  }

  // Queues a message behind the earlier ones of the same sender and receiver.
  fun enqueue(s: tSubmit) {
    var pair: (machine, machine);
    var q: seq[tMsg];
    pair = (s.sender, s.msg.dest);
    if (pair in queues) {
      q = queues[pair];
    }
    q += (sizeof(q), s.msg);
    queues[pair] = q;
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
    send m.dest, eNet, m;
  }

  // Keeps exactly one delivery step scheduled while anything is in flight.
  fun schedule() {
    var pairs: seq[(machine, machine)];
    var pair: (machine, machine);
    pairs = keys(queues);
    foreach (pair in pairs) {
      if (sizeof(queues[pair]) > 0 && !stepPending) {
        stepPending = true;
        send this, eStep;
      }
    }
  }

  // Every message in flight is lost.
  fun sever() {
    queues = default(map[(machine, machine), seq[tMsg]]);
  }

  // Every effect process waiting on the remote hears `Unreachable` once.
  fun notifyWatchers() {
    var w: machine;
    foreach (w in watching) {
      send w, eNoConn;
    }
    watching = default(set[machine]);
  }
}
