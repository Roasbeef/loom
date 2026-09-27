// The attachment worker: the weft task body job_runner.start_attach runs
// when the runtime performs effect.StartJob(key, job.Attach(..)).
//
// It resolves the target, connects a socket whose frames go to the frames
// inbox the runtime created for the job, publishes Prepared naming that
// inbox, tagged with the job's key, and waits for the acknowledgement. An
// acknowledged worker returns normally, which the weft relay reports as
// AllDelivered, tagged with the same key. The worker owns only its
// acknowledgement subject, which in the model is the worker itself.
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
  var framesInbox: int;
  var sock: machine;

  start state Init {
    entry (p: (terminal: machine, attempt: int, framesInbox: int)) {
      terminal = p.terminal;
      attempt = p.attempt;
      framesInbox = p.framesInbox;
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
      send terminal, ePrepared, (attempt = attempt, sock = sock, worker = this, framesInbox = framesInbox);
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
    send terminal, eOutcome, (attempt = attempt, completed = completed);
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
