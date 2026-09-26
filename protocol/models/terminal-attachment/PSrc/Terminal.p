// The terminal: one reducer plus the runtime that performs its effects.
//
// Stands for tui.step followed by runtime.perform. A reducer step handles one
// input (a tick, a key, a clock reading) and returns effects as values; the
// runtime performs them in a separate P step, and messages may arrive in
// between, as they may in the BEAM mailbox while the terminal runs. No other
// reducer step runs until the effects are performed: operator input and
// ticks are deferred while the Terminal is in `Performing`.
//
// Every inbox is created by the terminal (attachment.start_recorded makes
// the prepared, frames and outcomes subjects before the worker starts) and
// named here by an integer. The runtime buffers what arrives in `framesBox`,
// `preparedBox` and `outcomesBox`; a message for an inbox that was never
// created or has been discarded is dropped, which is what a discarded
// `Subject` amounts to once nothing selects on it again. The reducer reads
// those buffers the way tick.update_tick and interaction.update_ready_key
// drain the mailbox today; phase 2 of issue #530 turns the same reads into
// runtime-delivered messages, and the discipline modelled here (read an
// inbox only while the model holds it) is what that change must keep.

type tArrived = (sock: machine, msg: tMsg);
type tPrep = (attempt: int, sock: machine, worker: machine);

// attachment.Status: Idle when `opening` is false, otherwise
// Opening(run, prepared, frames, candidate) with the candidate present when
// `hasChan` holds. `ackTo` is the worker's acknowledgement subject.
type tCand = (
  opening: bool,
  attempt: int,
  preparedInbox: int,
  framesInbox: int,
  outcomesInbox: int,
  worker: machine,
  hasChan: bool,
  chan: tChan,
  ackTo: machine,
  captured: bool
);

// tui/effect.Effect, restricted to the model: a channel output, the
// attachment outputs Acknowledge, Abandon and CloseStray, and Discard.
enum tEffKind { EFF_OUT, EFF_ACK, EFF_ABANDON, EFF_CLOSE_STRAY, EFF_DISCARD }
type tEff = (kind: tEffKind, out: tOut, target: machine, attempt: int, status: tCand, inbox: int);

fun idleCand(): tCand {
  return default(tCand);
}

fun outEff(o: tOut): tEff {
  return (kind = EFF_OUT, out = o, target = default(machine), attempt = 0, status = idleCand(), inbox = 0);
}

machine Terminal {
  // Model.channel, Model.inbox, and the attempt that produced them.
  var hasLane: bool;
  var lane: tChan;
  var inbox: int;

  // Model.candidate.
  var cand: tCand;

  // The runtime's mailbox, by terminal-created inbox.
  var framesBox: map[int, seq[tArrived]];
  var preparedBox: map[int, seq[tPrep]];
  var outcomesBox: map[int, seq[bool]];

  // Model.outbox, and what the last step returned to the runtime.
  var outbox: seq[tEff];
  var effects: seq[tEff];

  var tickPending: bool;
  var quitting: bool;
  var nextInbox: int;
  var nextAttempt: int;
  var nextCmd: int;

  // Model.unconfirmed: the last command whose outcome is unknown.
  var unconfirmed: int;

  start state Init {
    entry {
      nextInbox = 1;
      nextAttempt = 1;
      nextCmd = 1;
      inbox = -1;
      unconfirmed = -1;
      cand = idleCand();
      goto Running;
    }
  }

  state Running {
    on eFrame do arriveFrame;
    on ePrepared do arrivePrepared;
    on eOutcome do arriveOutcome;

    // tick.update_tick: the candidate is polled before the adopted inbox is
    // drained, so an adoption in this tick swaps the inbox first.
    on eTick do {
      tickPending = false;
      pollCandidate(false);
      drainLane();
      finishStep();
      goto Performing;
    }

    on eClockRefresh do {
      var before: tChan;
      pollCandidate(false);
      drainLane();
      if (hasLane) {
        before = lane;
        lane = chanRefresh(lane);
        applyLaneUpdates(before, LOST_FAIL);
      }
      finishStep();
      goto Performing;
    }

    // Either lane's deadline may have passed; the candidate's is checked in
    // attachment.progress, the adopted lane's in inbound.tick_channel.
    on eClockDeadline do {
      var before: tChan;
      pollCandidate($);
      drainLane();
      if (hasLane && $) {
        before = lane;
        lane = chanExpire(lane);
        applyLaneUpdates(before, LOST_FAIL);
      }
      finishStep();
      goto Performing;
    }

    // A key applies ready traffic before it acts (update_ready_key), and a
    // locked composer turns every key but Escape and Ctrl-C into a notice.
    on eOpSubmit do {
      drainLane();
      if (!pending()) {
        submitMutation();
      }
      finishStep();
      goto Performing;
    }

    on eOpEscape do {
      if (pending()) {
        cancelPending();
      } else {
        drainLane();
      }
      finishStep();
      goto Performing;
    }

    on eOpOpen do {
      drainLane();
      beginOpen();
      finishStep();
      goto Performing;
    }

    on eOpQuit do {
      if (pending()) {
        cancelPending();
      } else {
        drainLane();
      }
      quit();
      finishStep();
      goto Performing;
    }
  }

  // runtime.perform. Arrivals are buffered; every other input waits.
  state Performing {
    defer eTick, eOpOpen, eOpSubmit, eOpEscape, eOpQuit, eClockRefresh, eClockDeadline;
    on eFrame do arriveFrame;
    on ePrepared do arrivePrepared;
    on eOutcome do arriveOutcome;

    on ePerform do {
      performAll();
      if (quitting) {
        goto Done;
      } else {
        goto Running;
      }
    }
  }

  // The terminal process has exited.
  state Done {
    ignore eFrame, ePrepared, eOutcome, eTick, ePerform, eOpOpen, eOpSubmit, eOpEscape, eOpQuit, eClockRefresh, eClockDeadline;
  }

  // -------------------------------------------------------------------------
  // Runtime: arrivals.
  // -------------------------------------------------------------------------

  fun wake() {
    if (!tickPending) {
      tickPending = true;
      send this, eTick;
    }
  }

  fun arriveFrame(p: tFramePayload) {
    var q: seq[tArrived];
    if (p.inbox in framesBox) {
      q = framesBox[p.inbox];
      q += (sizeof(q), (sock = p.sock, msg = p.msg));
      framesBox[p.inbox] = q;
      wake();
    }
  }

  fun arrivePrepared(p: tPreparedPayload) {
    var q: seq[tPrep];
    if (p.inbox in preparedBox) {
      q = preparedBox[p.inbox];
      q += (sizeof(q), (attempt = p.attempt, sock = p.sock, worker = p.worker));
      preparedBox[p.inbox] = q;
      wake();
    }
  }

  fun arriveOutcome(p: tOutcomePayload) {
    var q: seq[bool];
    if (p.inbox in outcomesBox) {
      q = outcomesBox[p.inbox];
      q += (sizeof(q), p.completed);
      outcomesBox[p.inbox] = q;
      wake();
    }
  }

  // -------------------------------------------------------------------------
  // Runtime: runtime.take and runtime.perform.
  // -------------------------------------------------------------------------

  // The adopted lane's outputs, then the candidate's, then the outbox.
  fun finishStep() {
    var i: int;
    effects = default(seq[tEff]);
    if (hasLane) {
      i = 0;
      while (i < sizeof(lane.out)) {
        effects += (sizeof(effects), outEff(lane.out[i]));
        i = i + 1;
      }
      lane.out = default(seq[tOut]);
    }
    if (cand.opening && cand.hasChan) {
      i = 0;
      while (i < sizeof(cand.chan.out)) {
        effects += (sizeof(effects), outEff(cand.chan.out[i]));
        i = i + 1;
      }
      cand.chan.out = default(seq[tOut]);
    }
    i = 0;
    while (i < sizeof(outbox)) {
      effects += (sizeof(effects), outbox[i]);
      i = i + 1;
    }
    outbox = default(seq[tEff]);
    send this, ePerform;
  }

  fun performAll() {
    var i: int;
    i = 0;
    while (i < sizeof(effects)) {
      performOne(effects[i]);
      i = i + 1;
    }
    effects = default(seq[tEff]);
  }

  fun performOut(o: tOut) {
    if (o.kind == TRANSMIT) {
      send o.sock, eWrite, (sock = o.sock, req = o.req);
    } else {
      send o.sock, eShut, (sock = o.sock,);
    }
  }

  fun performOne(e: tEff) {
    if (e.kind == EFF_OUT) {
      performOut(e.out);
    } else if (e.kind == EFF_ACK) {
      send e.target, eAck, (attempt = e.attempt,);
    } else if (e.kind == EFF_ABANDON) {
      cancelAttempt(e.status);
    } else if (e.kind == EFF_CLOSE_STRAY) {
      send e.target, eShut, (sock = e.target,);
    } else {
      framesBox -= (e.inbox);
    }
  }

  // attachment.cancel: cancel the worker, close what the attempt opened,
  // and discard its frames and prepared inboxes. A candidate's channel
  // performs what it had queued before its close.
  fun cancelAttempt(s: tCand) {
    var c: tChan;
    var q: seq[tPrep];
    var i: int;
    send s.worker, eCancel, (attempt = s.attempt,);
    if (s.hasChan) {
      c = chanClose(s.chan);
      i = 0;
      while (i < sizeof(c.out)) {
        performOut(c.out[i]);
        i = i + 1;
      }
    } else if (s.preparedInbox in preparedBox) {
      q = preparedBox[s.preparedInbox];
      if (sizeof(q) > 0) {
        send q[0].sock, eShut, (sock = q[0].sock,);
      }
    }
    framesBox -= (s.framesInbox);
    preparedBox -= (s.preparedInbox);
  }

  // -------------------------------------------------------------------------
  // Reducer: the adopted lane.
  // -------------------------------------------------------------------------

  // Model.pending_submission: the composer is locked behind an unsent command.
  fun pending(): bool {
    return hasLane && chanHasUnsent(lane);
  }

  // inbound.apply_channel_update for the updates a lane transition produced.
  fun applyLaneUpdates(before: tChan, why: tLoss) {
    var i: int;
    var u: tUp;
    i = 0;
    while (i < sizeof(lane.ups)) {
      u = lane.ups[i];
      if (u.cmd >= 0) {
        if (u.kind == UP_SENT) {
          announce eCmdResolved, (cmd = u.cmd, sock = lane.sock, disp = SENT);
        } else if (u.kind == UP_NOT_SENT) {
          announce eCmdResolved, (cmd = u.cmd, sock = lane.sock, disp = NOT_SENT);
        } else if (u.kind == UP_ACKED) {
          announce eCmdResolved, (cmd = u.cmd, sock = lane.sock, disp = ACKED);
        } else if (u.kind == UP_UNKNOWN) {
          unconfirmed = u.cmd;
          announce eCmdResolved, (cmd = u.cmd, sock = lane.sock, disp = UNKNOWN);
        }
      }
      i = i + 1;
    }
    lane.ups = default(seq[tUp]);
    if (before.phase != CLOSED && lane.phase == CLOSED) {
      announce eLaneClosed, (sock = lane.sock, why = why);
    }
  }

  // inbound.drain_connection over Model.inbox.
  fun drainLane() {
    var q: seq[tArrived];
    var a: tArrived;
    var before: tChan;
    if (!hasLane || !(inbox in framesBox)) {
      return;
    }
    while (sizeof(framesBox[inbox]) > 0) {
      q = framesBox[inbox];
      a = q[0];
      q -= (0);
      framesBox[inbox] = q;
      announce eApplied, (source = a.sock,);
      before = lane;
      lane = chanReceive(lane, a.msg);
      applyLaneUpdates(before, LOST_FAIL);
    }
  }

  // inbound.cancel_pending.
  fun cancelPending() {
    var before: tChan;
    if (hasLane) {
      before = lane;
      lane = chanCancelUnsent(lane);
      applyLaneUpdates(before, LOST_FAIL);
    }
  }

  // outbound.send_frame with a mutation, then outbound.apply_submission.
  fun submitMutation() {
    var cmd: int;
    var before: tChan;
    var u: tUp;
    cmd = nextCmd;
    nextCmd = nextCmd + 1;
    if (!hasLane) {
      return;
    }
    before = lane;
    lane = chanAdmitMutation(lane, cmd);
    if (sizeof(lane.ups) == 0) {
      announce eCmdAdmitted, (cmd = cmd, sock = lane.sock, disp = WAITING);
    } else {
      u = lane.ups[0];
      lane.ups = default(seq[tUp]);
      if (u.kind == UP_SENT) {
        announce eCmdAdmitted, (cmd = cmd, sock = lane.sock, disp = SENT);
      } else {
        announce eCmdAdmitted, (cmd = cmd, sock = lane.sock, disp = NOT_SENT);
      }
    }
  }

  // submit.quit. The candidate moves into its cancel effect; the adopted
  // channel queues its own close.
  fun quit() {
    var before: tChan;
    if (cand.opening) {
      outbox += (sizeof(outbox), (kind = EFF_ABANDON, out = default(tOut), target = default(machine), attempt = cand.attempt, status = cand, inbox = 0));
    }
    cand = idleCand();
    if (hasLane) {
      before = lane;
      lane = chanClose(lane);
      if (before.phase != CLOSED) {
        announce eLaneClosed, (sock = lane.sock, why = LOST_QUIT);
      }
    }
    announce eQuit;
    quitting = true;
  }

  // -------------------------------------------------------------------------
  // Reducer: the provisional attachment.
  // -------------------------------------------------------------------------

  // session_control.begin_open: unsent work for the old target is cancelled
  // first; a second attempt is refused while one is open.
  fun beginOpen() {
    var attempt: int;
    cancelPending();
    if (cand.opening) {
      return;
    }
    attempt = nextAttempt;
    nextAttempt = nextAttempt + 1;
    cand = idleCand();
    cand.opening = true;
    cand.attempt = attempt;
    cand.preparedInbox = nextInbox;
    cand.framesInbox = nextInbox + 1;
    cand.outcomesInbox = nextInbox + 2;
    nextInbox = nextInbox + 3;
    preparedBox[cand.preparedInbox] = default(seq[tPrep]);
    framesBox[cand.framesInbox] = default(seq[tArrived]);
    outcomesBox[cand.outcomesInbox] = default(seq[bool]);
    cand.worker = new AttachmentWorker((
      terminal = this,
      attempt = attempt,
      preparedInbox = cand.preparedInbox,
      framesInbox = cand.framesInbox,
      outcomesInbox = cand.outcomesInbox
    ));
  }

  // attachment.apply_updates for the candidate's channel. Returns true when
  // the advance failed.
  fun candidateUpdates(): bool {
    var i: int;
    var u: tUp;
    var failed: bool;
    failed = false;
    i = 0;
    while (i < sizeof(cand.chan.ups)) {
      u = cand.chan.ups[i];
      if (u.kind == UP_CAPTURED) {
        if (!cand.captured) {
          cand.captured = true;
          announce eCandidateCaptured, (attempt = cand.attempt, sock = cand.chan.sock);
        }
      } else if (u.kind != UP_NOTICED) {
        failed = true;
      }
      i = i + 1;
    }
    cand.chan.ups = default(seq[tUp]);
    return failed;
  }

  // attachment.poll followed by interaction.advance_candidate: prepare,
  // progress, settle one outcome, and the acknowledgement owed by the
  // advance that captured the initial cut.
  fun pollCandidate(expire: bool) {
    var before: tCand;
    var fq: seq[tArrived];
    var a: tArrived;
    var pq: seq[tPrep];
    var p: tPrep;
    var oq: seq[bool];
    var completed: bool;
    var failedAdvance: bool;
    if (!cand.opening) {
      return;
    }
    if (!cand.hasChan && sizeof(preparedBox[cand.preparedInbox]) > 0) {
      pq = preparedBox[cand.preparedInbox];
      p = pq[0];
      pq -= (0);
      preparedBox[cand.preparedInbox] = pq;
      cand.hasChan = true;
      cand.chan = chanStart(p.sock);
      cand.ackTo = p.worker;
      cand.captured = false;
    }
    before = cand;
    failedAdvance = false;
    if (cand.hasChan && !cand.captured) {
      while (!failedAdvance && !cand.captured && sizeof(framesBox[cand.framesInbox]) > 0) {
        fq = framesBox[cand.framesInbox];
        a = fq[0];
        fq -= (0);
        framesBox[cand.framesInbox] = fq;
        cand.chan = chanReceive(cand.chan, a.msg);
        failedAdvance = candidateUpdates();
      }
      if (!failedAdvance && !cand.captured && expire) {
        cand.chan = chanExpire(cand.chan);
        failedAdvance = candidateUpdates();
      }
    }

    // A failed advance is abandoned as it stood before the advance; the
    // writes and close the failing advance itself decided are dropped with
    // it, and cancel closes the socket once.
    if (failedAdvance) {
      failCandidate(before);
      return;
    }

    if (before.hasChan && !before.captured && cand.captured) {
      outbox += (sizeof(outbox), (kind = EFF_ACK, out = default(tOut), target = cand.ackTo, attempt = cand.attempt, status = idleCand(), inbox = 0));
    }

    if (sizeof(outcomesBox[cand.outcomesInbox]) > 0) {
      oq = outcomesBox[cand.outcomesInbox];
      completed = oq[0];
      oq -= (0);
      outcomesBox[cand.outcomesInbox] = oq;
      if (completed) {
        adoptCandidate();
      } else {
        failCandidate(cand);
      }
    }
  }

  // attachment.failed, then candidate_outcome's Failed arm.
  fun failCandidate(status: tCand) {
    outbox += (sizeof(outbox), (kind = EFF_ABANDON, out = default(tOut), target = default(machine), attempt = status.attempt, status = status, inbox = 0));
    cand = idleCand();
    cancelPending();
    announce eCandidateFailed, (attempt = status.attempt,);
  }

  // attachment.adopt, then candidate_outcome's Adopted arm: cancel unsent
  // work, retire the old lane while its identity is still visible, release
  // its queued outputs, discard its inbox, swap, and ask for models.
  fun adoptCandidate() {
    var adopted: tCand;
    var before: tChan;
    var i: int;
    if (!cand.captured) {
      failCandidate(cand);
      return;
    }

    // connection.adopt: the socket actor may have exited.
    if (choose(8) == 0) {
      failCandidate(cand);
      return;
    }
    adopted = cand;
    cand = idleCand();
    cancelPending();
    if (hasLane) {
      before = lane;
      lane = chanRetire(lane);
      applyLaneUpdates(before, LOST_RETIRE);
      i = 0;
      while (i < sizeof(lane.out)) {
        outbox += (sizeof(outbox), outEff(lane.out[i]));
        i = i + 1;
      }
      lane.out = default(seq[tOut]);
      outbox += (sizeof(outbox), (kind = EFF_DISCARD, out = default(tOut), target = default(machine), attempt = 0, status = idleCand(), inbox = inbox));
    }
    hasLane = true;
    lane = adopted.chan;
    inbox = adopted.framesInbox;
    announce eVisible, (attempt = adopted.attempt, sock = lane.sock);
    lane = chanAdmitRead(lane);
  }
}
