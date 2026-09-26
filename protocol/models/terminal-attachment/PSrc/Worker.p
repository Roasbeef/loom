// The attachment worker: the Weft task body in attachment.start_recorded.
//
// It resolves the target, connects a socket whose frames go to the
// terminal-created frames inbox, publishes Prepared to the terminal-created
// prepared inbox, and waits for the acknowledgement. An acknowledged worker
// returns normally, which the weft relay reports as AllDelivered on the
// outcomes inbox. The worker owns only its acknowledgement subject, which in
// the model is the worker itself.
//
// Cancellation (weft.cancel) kills the worker; the socket guardian then sees
// the startup worker exit abnormally and kills the socket (AttemptGone in
// host/websocket.start_owned_socket). After a normal return the guardian
// keeps the socket alive for the terminal, and a later cancel does nothing.
//
// Whether the attempt's 90 s deadline fires in a given run is the
// environment's choice, made when the worker starts. Runs in which it never
// fires are the ones in which the protocol must make progress without it.
machine AttachmentWorker {
  var terminal: machine;
  var attempt: int;
  var preparedInbox: int;
  var framesInbox: int;
  var outcomesInbox: int;
  var sock: machine;

  start state Init {
    entry (p: (terminal: machine, attempt: int, preparedInbox: int, framesInbox: int, outcomesInbox: int)) {
      terminal = p.terminal;
      attempt = p.attempt;
      preparedInbox = p.preparedInbox;
      framesInbox = p.framesInbox;
      outcomesInbox = p.outcomesInbox;
      announce eWorkerStarted, (attempt = attempt,);
      if ($) {
        new Deadline(this);
      }
      send this, eStep;
      goto Connecting;
    }
  }

  state Connecting {
    on eStep do {
      // Resolution through daemon control or the websocket handshake failed.
      if (choose(8) == 0) {
        report(false);
        goto Ended;
      }
      sock = new Socket((terminal = terminal, inbox = framesInbox, attempt = attempt));
      send terminal, ePrepared, (inbox = preparedInbox, attempt = attempt, sock = sock, worker = this);
      goto AwaitingAck;
    }

    on eCancel do {
      report(false);
      goto Ended;
    }

    on eDeadline do {
      report(false);
      goto Ended;
    }

    ignore eAck;
  }

  state AwaitingAck {
    on eAck do {
      report(true);
      goto Ended;
    }

    on eCancel do {
      send sock, eGuardianKill, (sock = sock,);
      report(false);
      goto Ended;
    }

    // process.receive(acknowledged, within_ms) returned Error(Nil).
    on eDeadline do {
      send sock, eWorkerClose, (sock = sock,);
      report(false);
      goto Ended;
    }
  }

  state Ended {
    entry {
      announce eWorkerEnded, (attempt = attempt,);
    }
    ignore eAck, eCancel, eDeadline, eStep;
  }

  fun report(completed: bool) {
    send terminal, eOutcome, (inbox = outcomesInbox, attempt = attempt, completed = completed);
  }
}

// Fires one attempt's deadline at a time the scheduler chooses.
machine Deadline {
  start state Fire {
    entry (worker: machine) {
      send worker, eDeadline;
    }
  }
}
