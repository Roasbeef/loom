// The properties the model checks. Each spec is named after the code rule
// it encodes; the comment above it cites where that rule lives.

// S1. Session replacement is fail-preserving.
//
// packages/tui/CLAUDE.md, Invariants; attachment.poll, attachment.adopt and
// interaction.candidate_outcome. The visible session changes only for an
// attempt whose initial cut was validated (Captured), whose worker completed
// (weft.AllDelivered after the acknowledgement), and whose adoption check
// passed; an attempt that failed never becomes visible.
spec ReplacementIsFailPreserving observes eCandidateCaptured, eOutcome, eCandidateFailed, eVisible {
  var captured: set[int];
  var completed: set[int];
  var failed: set[int];

  start state Watching {
    on eCandidateCaptured do (p: tAttemptSockPayload) {
      captured += (p.attempt);
    }

    on eOutcome do (p: tOutcomePayload) {
      if (p.completed) {
        completed += (p.attempt);
      }
    }

    on eCandidateFailed do (p: tAttemptPayload) {
      failed += (p.attempt);
    }

    on eVisible do (p: tAttemptSockPayload) {
      assert p.attempt in captured, format("attempt {0} adopted without a validated initial cut", p.attempt);
      assert p.attempt in completed, format("attempt {0} adopted before its worker completed", p.attempt);
      assert !(p.attempt in failed), format("failed attempt {0} changed the visible session", p.attempt);
    }
  }
}

// S2. No stale repaint.
//
// packages/tui/CLAUDE.md, "Session replacement is fail-preserving" (late
// packets from old subjects cannot repaint the adopted view) and "Every
// inbox the terminal reads is created by the terminal";
// interaction.candidate_outcome (Discard of the old inbox before the swap)
// and tick.update_tick (the candidate is polled before the inbox drain).
// Every message reduced into the visible lane came from the socket that lane
// was adopted with.
spec NoStaleRepaint observes eVisible, eApplied {
  var visible: machine;

  start state Watching {
    on eVisible do (p: tAttemptSockPayload) {
      visible = p.sock;
    }

    on eApplied do (p: tAppliedPayload) {
      assert p.source == visible, format("a frame from {0} was applied to the lane adopted with {1}", p.source, visible);
    }
  }
}

// S3. Mutation custody.
//
// ADR-010; session_channel.admit, flush_queued, fail, retire, cancel_unsent;
// packages/tui/CLAUDE.md "Uncertainty survives attachment replacement". A
// sent mutation is written once and applied by the daemon at most once; a
// lost reply is reported as UnknownOutcome exactly once; a waiting command is
// sent exactly once or reported DefinitelyNotSent exactly once, and never on
// another attachment. The hot state is the liveness half: while the terminal
// runs, no command stays waiting or sent-and-unresolved forever. A sent
// command whose lane is closed by quit is exempt: submit.quit reports
// nothing for it, and the process is exiting.
spec MutationCustody observes eCmdAdmitted, eCmdResolved, eLaneClosed, eWrite, eDaemonApplied, eQuit {
  // Commands currently waiting or sent and unresolved, with their lane.
  var waiting: map[int, machine];
  var inFlight: map[int, machine];
  var written: set[int];
  var applied: set[int];
  var resolved: set[int];
  var exited: bool;

  start cold state Settled {
    on eCmdAdmitted do (p: tCmdPayload) {
      admitted(p);
    }
    on eCmdResolved do (p: tCmdPayload) {
      resolve(p);
    }
    on eLaneClosed do (p: tLanePayload) {
      laneClosed(p);
    }
    on eWrite do (p: tWritePayload) {
      wrote(p);
    }
    on eDaemonApplied do (p: tAppliedCmdPayload) {
      daemonApplied(p);
    }
    on eQuit do {
      exited = true;
      goto Exited;
    }
  }

  hot state Outstanding {
    on eCmdAdmitted do (p: tCmdPayload) {
      admitted(p);
    }
    on eCmdResolved do (p: tCmdPayload) {
      resolve(p);
    }
    on eLaneClosed do (p: tLanePayload) {
      laneClosed(p);
    }
    on eWrite do (p: tWritePayload) {
      wrote(p);
    }
    on eDaemonApplied do (p: tAppliedCmdPayload) {
      daemonApplied(p);
    }
    on eQuit do {
      exited = true;
      goto Exited;
    }
  }

  // After quit the safety checks still apply; nothing is owed any more.
  cold state Exited {
    on eCmdAdmitted do (p: tCmdPayload) {
      admitted(p);
    }
    on eCmdResolved do (p: tCmdPayload) {
      resolve(p);
    }
    on eLaneClosed do (p: tLanePayload) {
      laneClosed(p);
    }
    on eWrite do (p: tWritePayload) {
      wrote(p);
    }
    on eDaemonApplied do (p: tAppliedCmdPayload) {
      daemonApplied(p);
    }
    ignore eQuit;
  }

  fun settle() {
    if (exited) {
      return;
    }
    if (sizeof(waiting) + sizeof(inFlight) > 0) {
      goto Outstanding;
    } else {
      goto Settled;
    }
  }

  fun admitted(p: tCmdPayload) {
    assert !(p.cmd in resolved) && !(p.cmd in waiting) && !(p.cmd in inFlight), format("command {0} admitted twice", p.cmd);
    if (p.disp == WAITING) {
      waiting[p.cmd] = p.sock;
    } else if (p.disp == SENT) {
      inFlight[p.cmd] = p.sock;
    } else {
      resolved += (p.cmd);
    }
    settle();
  }

  fun resolve(p: tCmdPayload) {
    assert !(p.cmd in resolved), format("command {0} resolved twice ({1})", p.cmd, p.disp);
    if (p.disp == SENT) {
      assert p.cmd in waiting, format("command {0} sent from the unsent slot without waiting there", p.cmd);
      assert waiting[p.cmd] == p.sock, format("waiting command {0} crossed to another attachment", p.cmd);
      waiting -= (p.cmd);
      inFlight[p.cmd] = p.sock;
    } else if (p.disp == NOT_SENT) {
      assert p.cmd in waiting, format("command {0} reported not sent without waiting", p.cmd);
      waiting -= (p.cmd);
      resolved += (p.cmd);
    } else {
      assert p.cmd in inFlight, format("command {0} resolved {1} without being sent", p.cmd, p.disp);
      inFlight -= (p.cmd);
      resolved += (p.cmd);
    }
    settle();
  }

  // session_channel.fail and retire report the unsent command and the
  // unknown outcome before the lane closes; close at quit reports only the
  // unsent command, which cancel_pending already did.
  fun laneClosed(p: tLanePayload) {
    var cmds: seq[int];
    var i: int;
    cmds = keys(waiting);
    i = 0;
    while (i < sizeof(cmds)) {
      assert waiting[cmds[i]] != p.sock, format("lane closed ({0}) with command {1} still waiting on it", p.why, cmds[i]);
      i = i + 1;
    }
    cmds = keys(inFlight);
    i = 0;
    while (i < sizeof(cmds)) {
      if (inFlight[cmds[i]] == p.sock) {
        assert p.why == LOST_QUIT, format("lane closed ({0}) without an UnknownOutcome for sent command {1}", p.why, cmds[i]);
        inFlight -= (cmds[i]);
      }
      i = i + 1;
    }
    settle();
  }

  fun wrote(p: tWritePayload) {
    if (p.req.kind == MUTATION) {
      assert !(p.req.cmd in written), format("command {0} written to the wire twice", p.req.cmd);
      written += (p.req.cmd);
    }
  }

  fun daemonApplied(p: tAppliedCmdPayload) {
    assert !(p.cmd in applied), format("daemon applied command {0} twice", p.cmd);
    applied += (p.cmd);
  }
}

// S4. No write follows a close.
//
// session_channel.Out, session_channel.close and runtime.take: a channel
// queues nothing after its own Shut, and effects on one socket are performed in the order the lane
// decided them. This is the cross-process face of the property-test rule
// "no Transmit follows a Shut on the same socket".
spec NoWriteAfterShut observes eWrite, eShut {
  var shut: set[machine];

  start state Watching {
    on eWrite do (p: tWritePayload) {
      assert !(p.sock in shut), format("request {0} written to {1} after the terminal closed it", p.req.id, p.sock);
    }

    on eShut do (p: tSockPayload) {
      shut += (p.sock);
    }
  }
}

// S4b. Each socket is closed at most once by the terminal.
//
// session_channel.close and session_channel.receive leave a Closed lane
// closed: a quit after a failure, or a second transport-loss report, queues
// no second Shut. The model reproduced the double close before that guard
// existed; README.md, finding F1, has the traces.
spec ShutAtMostOnce observes eShut {
  var shut: set[machine];

  start state Watching {
    on eShut do (p: tSockPayload) {
      assert !(p.sock in shut), format("the terminal closed {0} a second time", p.sock);
      shut += (p.sock);
    }
  }
}

// S5. The worker is never stranded.
//
// attachment.acknowledging and attachment.cancel; packages/tui/CLAUDE.md
// "Every inbox the terminal reads is created by the terminal". A worker
// that published Prepared is eventually acknowledged, cancelled, or ended by
// its own deadline. Runs in which the deadline never fires are the ones that
// test this: the protocol must not rely on the deadline for progress.
spec WorkerNeverStranded observes ePrepared, eWorkerEnded {
  var waiting: set[int];

  start cold state Idle {
    on ePrepared do (p: tPreparedPayload) {
      waiting += (p.attempt);
      goto Waiting;
    }
    on eWorkerEnded do (p: tAttemptPayload) {
      waiting -= (p.attempt);
    }
  }

  hot state Waiting {
    on ePrepared do (p: tPreparedPayload) {
      waiting += (p.attempt);
    }
    on eWorkerEnded do (p: tAttemptPayload) {
      waiting -= (p.attempt);
      if (sizeof(waiting) == 0) {
        goto Idle;
      }
    }
  }
}

// S6. Quit releases everything the terminal owned.
//
// submit.quit, attachment.cancel and session_channel.close. After quit,
// every socket opened for the terminal and every attachment worker it
// started eventually stops, whether closed by the terminal, killed by its
// guardian after cancellation, or closed from the daemon side.
spec QuitReleasesEverything observes eQuit, eSocketOpened, eSocketDown, eWorkerStarted, eWorkerEnded {
  var sockets: set[machine];
  var workers: set[int];

  start cold state Running {
    on eSocketOpened do (p: tSockAttemptPayload) {
      sockets += (p.sock);
    }
    on eSocketDown do (p: tSockPayload) {
      sockets -= (p.sock);
    }
    on eWorkerStarted do (p: tAttemptPayload) {
      workers += (p.attempt);
    }
    on eWorkerEnded do (p: tAttemptPayload) {
      workers -= (p.attempt);
    }
    on eQuit do {
      check();
    }
  }

  hot state Releasing {
    on eSocketOpened do (p: tSockAttemptPayload) {
      sockets += (p.sock);
    }
    on eSocketDown do (p: tSockPayload) {
      sockets -= (p.sock);
      check();
    }
    on eWorkerStarted do (p: tAttemptPayload) {
      workers += (p.attempt);
    }
    on eWorkerEnded do (p: tAttemptPayload) {
      workers -= (p.attempt);
      check();
    }
  }

  cold state Released {
    on eSocketOpened do (p: tSockAttemptPayload) {
      sockets += (p.sock);
      check();
    }
    on eWorkerStarted do (p: tAttemptPayload) {
      workers += (p.attempt);
      check();
    }
    ignore eSocketDown, eWorkerEnded;
  }

  fun check() {
    if (sizeof(sockets) + sizeof(workers) == 0) {
      goto Released;
    } else {
      goto Releasing;
    }
  }
}

// S7. At most one request in flight per socket, and ids are never reused.
//
// session_channel.admit, send, credit and capture_again; the
// "A commit notice is idempotent and order-free" and "A pushed frame never
// owns the wire" invariants. Observed across the wire: the terminal writes
// a request on a socket only after the daemon has answered the previous one
// there, and request ids on one socket strictly increase. A deferred notice
// (Refresh.Due) is the path that tests this.
spec OneRequestInFlight observes eWrite, eFrame {
  var outstanding: map[machine, int];
  var lastId: map[machine, int];

  start state Watching {
    on eWrite do (p: tWritePayload) {
      if (p.sock in outstanding) {
        assert false, format("request {0} written to {1} while request {2} is unanswered", p.req.id, p.sock, outstanding[p.sock]);
      }
      if (p.sock in lastId) {
        assert p.req.id > lastId[p.sock], format("request id {0} reused on {1}", p.req.id, p.sock);
      }
      lastId[p.sock] = p.req.id;
      outstanding[p.sock] = p.req.id;
    }

    on eFrame do (p: tFramePayload) {
      if (p.sock in outstanding && p.msg.replyTo == outstanding[p.sock] && p.msg.kind != M_COMMITTED) {
        outstanding -= (p.sock);
      }
    }
  }
}
