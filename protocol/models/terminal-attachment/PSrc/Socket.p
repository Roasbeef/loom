// One websocket connection, seen from both ends of the wire.
//
// The Socket stands for the stratus actor and its guardian
// (packages/host/src/host/websocket.gleam) together with the daemon's
// ClientGateway handler for that one connection (packages/client/protocol.md).
// P delivers the events one machine sends to another in order, which is the
// one ordered stream per socket the transport gives; nothing orders two
// sockets, or a socket and a worker, against each other.
//
// The daemon side answers one correlated request at a time, streams a
// credited snapshot (snapshot_begin, one snapshot_next, snapshot_end), may
// push commit notices once subscribed, and may lose a mutation's reply with
// the connection. A Fuse breaks the connection from the network side at an
// arbitrary point; stratus reports a failed write as NetworkFault and keeps
// running, so a Fuse may deliver NetworkFault before the final Closed.
// A close the terminal requests (websocket.close, a user Stop) and a kill
// by the guardian deliver nothing to the inbox, because stratus calls
// on_close only for a close frame or a TCP close.
machine Socket {
  var terminal: machine;
  var inbox: int;
  var attempt: int;
  var pending: seq[tReq];
  var head: int;
  var pushes: int;
  var subscribed: bool;
  var transferOpen: bool;

  start state Init {
    entry (p: (terminal: machine, inbox: int, attempt: int)) {
      terminal = p.terminal;
      inbox = p.inbox;
      attempt = p.attempt;
      head = 3;
      pushes = 2;
      announce eSocketOpened, (sock = this, attempt = attempt);
      if (choose(4) == 0) {
        new Fuse(this);
      }
      goto Open;
    }
  }

  state Open {
    on eWrite do (p: tWritePayload) {
      pending += (sizeof(pending), p.req);
      send this, eServe;
    }

    on eServe do {
      if (serve()) {
        goto Down;
      }
    }

    on eFuse do {
      if ($) {
        deliver(M_NETWORK_FAULT, 0, 0);
      }
      deliver(M_CLOSED, 0, 0);
      goto Down;
    }

    on eShut goto Down;
    on eGuardianKill goto Down;
    on eWorkerClose goto Down;
  }

  state Down {
    entry {
      announce eSocketDown, (sock = this,);
    }
    ignore eWrite, eServe, eFuse, eShut, eGuardianKill, eWorkerClose;
  }

  fun deliver(kind: tMsgKind, replyTo: int, at: int) {
    send terminal, eFrame, (inbox = inbox, sock = this, msg = (kind = kind, replyTo = replyTo, at = at));
  }

  // A commit by any writer to the session. The notice carries the sequence,
  // never the record; a repeated older sequence is also legal.
  fun maybePush() {
    if (subscribed && pushes > 0 && $) {
      pushes = pushes - 1;
      if ($) {
        head = head + 1;
      }
      deliver(M_COMMITTED, 0, head - 1);
    }
  }

  // Serves the oldest request. Returns true when the connection dropped
  // instead of replying.
  fun serve(): bool {
    var r: tReq;
    if (sizeof(pending) == 0) {
      return false;
    }
    r = pending[0];
    pending -= (0);
    maybePush();
    if (r.kind == SUBSCRIBE || r.kind == CATCH_UP) {
      subscribed = true;
      transferOpen = true;
      deliver(M_BEGIN, r.id, 0);
    } else if (r.kind == SNAPSHOT_NEXT) {
      // A credit outside an open transfer would be a terminal bug; the
      // gateway would refuse it. The model's terminal never sends one.
      assert transferOpen, format("snapshot_next {0} without an open transfer", r.id);
      transferOpen = false;
      deliver(M_END, r.id, head);
    } else if (r.kind == MUTATION) {
      announce eDaemonApplied, (cmd = r.cmd, sock = this);
      head = head + 1;
      if (choose(4) == 0) {
        deliver(M_CLOSED, 0, 0);
        return true;
      }
      deliver(M_MUT_REPLY, r.id, 0);
    } else {
      deliver(M_READ_REPLY, r.id, 0);
    }
    maybePush();
    return false;
  }
}

// Breaks one socket from the network or daemon side at a time the scheduler
// chooses.
machine Fuse {
  start state Fire {
    entry (target: machine) {
      send target, eFuse;
    }
  }
}
