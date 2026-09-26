// The session channel as pure functions over a value.
//
// Stands for packages/tui/src/tui/session_channel.gleam. Like the Gleam
// module, every function here is a transition over its argument: writes and
// closes are queued on `out` (session_channel.Out) and updates on `ups`
// (session_channel.Update) for the caller to take. Snapshot chunks, payload
// validation, approvals, lookups and history pages are abstracted away; one
// credit (SNAPSHOT_NEXT) separates BEGIN from END.

// session_channel.Phase. AWAIT_REPLY carries its intent in `intent`.
enum tPhase { AWAIT_BEGIN, RECEIVING, AWAIT_REPLY, READY, CLOSED }

// session_channel.Intent, restricted to the two the model needs.
enum tIntent { NO_INTENT, READ_INTENT, MUTATION_INTENT }

enum tOutKind { TRANSMIT, SHUT }
type tOut = (kind: tOutKind, sock: machine, req: tReq);

// session_channel.Update, restricted to what the model observes.
enum tUpKind { UP_CAPTURED, UP_SENT, UP_NOT_SENT, UP_ACKED, UP_UNKNOWN, UP_FAILED, UP_READ_DONE, UP_NOTICED }
type tUp = (kind: tUpKind, cmd: int);

// session_channel.Channel. `queuedIntent`/`queuedCmd` is the one retained
// outbound slot (ADR-010); `hasCut`/`cutSeq` is `cut` and its next_seq;
// `due` is Refresh.Due.
type tChan = (
  sock: machine,
  phase: tPhase,
  reqId: int,
  nextId: int,
  intent: tIntent,
  cmd: int,
  queuedIntent: tIntent,
  queuedCmd: int,
  hasCut: bool,
  cutSeq: int,
  due: bool,
  out: seq[tOut],
  ups: seq[tUp]
);

fun chanUp(c: tChan, kind: tUpKind, cmd: int): tChan {
  var next: tChan;
  next = c;
  next.ups += (sizeof(next.ups), (kind = kind, cmd = cmd));
  return next;
}

// session_channel.emit: a live lane queues the write.
fun chanEmit(c: tChan, kind: tReqKind, id: int, cmd: int): tChan {
  var next: tChan;
  next = c;
  next.out += (sizeof(next.out), (kind = TRANSMIT, sock = c.sock, req = (kind = kind, id = id, cmd = cmd)));
  return next;
}

// session_channel.start_recorded: request 1 is the subscribe.
fun chanStart(sock: machine): tChan {
  var c: tChan;
  c = (
    sock = sock,
    phase = AWAIT_BEGIN,
    reqId = 1,
    nextId = 2,
    intent = NO_INTENT,
    cmd = -1,
    queuedIntent = NO_INTENT,
    queuedCmd = -1,
    hasCut = false,
    cutSeq = 0,
    due = false,
    out = default(seq[tOut]),
    ups = default(seq[tUp])
  );
  return chanEmit(c, SUBSCRIBE, 1, -1);
}

// session_channel.take_outputs, for the runtime.
fun chanTakeOuts(c: tChan): tChan {
  var next: tChan;
  next = c;
  next.out = default(seq[tOut]);
  return next;
}

fun chanTakeUps(c: tChan): tChan {
  var next: tChan;
  next = c;
  next.ups = default(seq[tUp]);
  return next;
}

// session_channel.in_flight.
fun chanInFlight(c: tChan): bool {
  return c.phase == AWAIT_BEGIN || c.phase == RECEIVING || c.phase == AWAIT_REPLY;
}

// session_channel.can_mutate, with the role fixed to Operator: a lane may
// mutate once it holds an authenticated attachment from a cut.
fun chanCanMutate(c: tChan): bool {
  return c.phase != CLOSED && c.hasCut;
}

// session_channel.mutation_available.
fun chanMutationAvailable(c: tChan): bool {
  var available: bool;
  available = false;
  if (c.phase == READY) {
    available = true;
  } else if (c.phase == AWAIT_BEGIN || c.phase == RECEIVING) {
    available = c.hasCut;
  } else if (c.phase == AWAIT_REPLY && c.intent == READ_INTENT) {
    available = c.hasCut;
  }
  return chanCanMutate(c) && available && c.queuedIntent == NO_INTENT;
}

// session_channel.has_unsent.
fun chanHasUnsent(c: tChan): bool {
  return c.queuedIntent == MUTATION_INTENT;
}

// session_channel.send: allocate the next id and put the command on the wire.
fun chanSend(c: tChan, intent: tIntent, cmd: int): tChan {
  var next: tChan;
  var kind: tReqKind;
  next = c;
  next.phase = AWAIT_REPLY;
  next.intent = intent;
  next.cmd = cmd;
  next.reqId = c.nextId;
  next.nextId = c.nextId + 1;
  kind = READ;
  if (intent == MUTATION_INTENT) {
    kind = MUTATION;
  }
  return chanEmit(next, kind, next.reqId, cmd);
}

// session_channel.capture_again.
fun chanCaptureAgain(c: tChan): tChan {
  var next: tChan;
  next = c;
  next.phase = AWAIT_BEGIN;
  next.reqId = c.nextId;
  next.nextId = c.nextId + 1;
  return chanEmit(next, CATCH_UP, next.reqId, -1);
}

// session_channel.credit.
fun chanCredit(c: tChan): tChan {
  var next: tChan;
  next = c;
  next.phase = RECEIVING;
  next.reqId = c.nextId;
  next.nextId = c.nextId + 1;
  return chanEmit(next, SNAPSHOT_NEXT, next.reqId, -1);
}

// session_channel.close (session_channel.gleam:1083): Closed, the unsent
// slot dropped, the Shut queued. A lane is closed once: close on a lane that
// is already Closed returns it unchanged and queues no second Shut.
fun chanClose(c: tChan): tChan {
  var next: tChan;
  next = c;
  if (c.phase == CLOSED) {
    return next;
  }
  next.phase = CLOSED;
  next.queuedIntent = NO_INTENT;
  next.queuedCmd = -1;
  next.out += (sizeof(next.out), (kind = SHUT, sock = c.sock, req = (kind = READ, id = 0, cmd = -1)));
  return next;
}

// session_channel.fail: the outcome is read from the lane as it stood, the
// unsent command is reported first, then the lane closes.
fun chanFail(c: tChan): tChan {
  var next: tChan;
  next = c;
  if (chanHasUnsent(c)) {
    next = chanUp(next, UP_NOT_SENT, c.queuedCmd);
  }
  if (c.phase == AWAIT_REPLY && c.intent == MUTATION_INTENT) {
    next = chanUp(next, UP_UNKNOWN, c.cmd);
  }
  next = chanUp(next, UP_FAILED, -1);
  return chanClose(next);
}

// session_channel.retire: fail without the Failed update, and nothing at
// all on a lane that is already Closed.
fun chanRetire(c: tChan): tChan {
  var next: tChan;
  var kept: seq[tUp];
  var i: int;
  if (c.phase == CLOSED) {
    return c;
  }
  next = chanFail(c);
  kept = default(seq[tUp]);
  i = 0;
  while (i < sizeof(next.ups)) {
    if (next.ups[i].kind != UP_FAILED) {
      kept += (sizeof(kept), next.ups[i]);
    }
    i = i + 1;
  }
  next.ups = kept;
  return next;
}

// session_channel.cancel_unsent.
fun chanCancelUnsent(c: tChan): tChan {
  var next: tChan;
  next = c;
  if (chanHasUnsent(c)) {
    next = chanUp(next, UP_NOT_SENT, c.queuedCmd);
    next.queuedIntent = NO_INTENT;
    next.queuedCmd = -1;
  }
  return next;
}

// session_channel.flush_queued: the retained command is re-checked against
// the fresh cut, then sent exactly once or reported definitely not sent.
fun chanFlushQueued(c: tChan): tChan {
  var next: tChan;
  var intent: tIntent;
  var cmd: int;
  next = c;
  if (c.queuedIntent == NO_INTENT) {
    return next;
  }
  intent = c.queuedIntent;
  cmd = c.queuedCmd;
  next.queuedIntent = NO_INTENT;
  next.queuedCmd = -1;
  if (intent == MUTATION_INTENT && !chanCanMutate(next)) {
    return chanUp(next, UP_NOT_SENT, cmd);
  }
  next = chanSend(next, intent, cmd);
  return chanUp(next, UP_SENT, cmd);
}

// session_channel.send_queued: every transition back to Ready passes here;
// a waiting command goes first and a deferred notice after it.
fun chanSendQueued(c: tChan): tChan {
  var next: tChan;
  next = chanFlushQueued(c);
  if (next.phase == READY && next.due && next.hasCut) {
    next.due = false;
    next = chanCaptureAgain(next);
  }
  return next;
}

// session_channel.capture_or_defer.
fun chanCaptureOrDefer(c: tChan): tChan {
  var next: tChan;
  next = c;
  if (!c.hasCut || c.phase == CLOSED) {
    return next;
  }
  if (c.phase == READY) {
    next.due = false;
    return chanCaptureAgain(next);
  }
  next.due = true;
  return next;
}

// session_channel.notified: a stale sequence says nothing new.
fun chanNotified(c: tChan, seqNo: int): tChan {
  var next: tChan;
  next = chanUp(c, UP_NOTICED, -1);
  if (c.hasCut && seqNo < c.cutSeq) {
    return next;
  }
  return chanCaptureOrDefer(next);
}

// session_channel.admit for a mutation. Returns the lane with the
// disposition as its last update (UP_SENT, UP_NOT_SENT) or with the command
// queued (WAITING, no update).
fun chanAdmitMutation(c: tChan, cmd: int): tChan {
  var next: tChan;
  next = c;
  if (c.phase == CLOSED || !chanCanMutate(c) || !chanMutationAvailable(c)) {
    return chanUp(next, UP_NOT_SENT, cmd);
  }
  if (c.phase == READY && c.queuedIntent == NO_INTENT) {
    next = chanSend(next, MUTATION_INTENT, cmd);
    return chanUp(next, UP_SENT, cmd);
  }
  if (c.queuedIntent == NO_INTENT) {
    next.queuedIntent = MUTATION_INTENT;
    next.queuedCmd = cmd;
    return next;
  }
  return chanUp(next, UP_NOT_SENT, cmd);
}

// session_channel.admit for a read (the models request sent at adoption).
fun chanAdmitRead(c: tChan): tChan {
  var next: tChan;
  next = c;
  if (c.phase == CLOSED) {
    return next;
  }
  if (c.phase == READY && c.queuedIntent == NO_INTENT) {
    return chanSend(next, READ_INTENT, -1);
  }
  if (c.queuedIntent == NO_INTENT) {
    next.queuedIntent = READ_INTENT;
    next.queuedCmd = -1;
  }
  return next;
}

// session_channel.receive (session_channel.gleam:629). A transport loss
// fails an open lane (the arm at line 644); a later report of the same loss
// finds the lane Closed and does nothing, because a socket reports its end
// more than once (NetworkFault, then the transport's Closed). Pushes are read
// in every phase but Closed. A correlated frame must name the outstanding
// request, and a Ready lane has none.
fun chanReceive(c: tChan, m: tMsg): tChan {
  var next: tChan;
  next = c;
  if (m.kind == M_CLOSED || m.kind == M_NETWORK_FAULT) {
    if (c.phase == CLOSED) {
      return next;
    }
    return chanFail(c);
  }
  if (c.phase == CLOSED) {
    return next;
  }
  if (m.kind == M_COMMITTED) {
    return chanNotified(c, m.at);
  }
  if (c.phase == READY || m.replyTo != c.reqId) {
    return chanFail(c);
  }
  if (c.phase == AWAIT_BEGIN && m.kind == M_BEGIN) {
    return chanCredit(c);
  }
  if (c.phase == RECEIVING && m.kind == M_END) {
    next.phase = READY;
    next.hasCut = true;
    next.cutSeq = m.at;
    next = chanUp(next, UP_CAPTURED, -1);
    return chanSendQueued(next);
  }
  if (c.phase == AWAIT_REPLY && c.intent == MUTATION_INTENT && m.kind == M_MUT_REPLY) {
    next.phase = READY;
    next = chanUp(next, UP_ACKED, c.cmd);
    return chanSendQueued(next);
  }
  if (c.phase == AWAIT_REPLY && c.intent == READ_INTENT && m.kind == M_READ_REPLY) {
    next.phase = READY;
    next = chanUp(next, UP_READ_DONE, -1);
    return chanSendQueued(next);
  }
  return chanFail(c);
}

// session_channel.tick when the request deadline has passed.
fun chanExpire(c: tChan): tChan {
  if (chanInFlight(c)) {
    return chanFail(c);
  }
  return c;
}

// session_channel.tick when the 250 ms idle refresh has fallen due.
fun chanRefresh(c: tChan): tChan {
  if (c.phase == READY && c.hasCut) {
    return chanCaptureAgain(c);
  }
  return c;
}
