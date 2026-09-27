// The terminal: one reducer plus the runtime that performs its effects.
//
// Stands for tui.step followed by runtime.perform. A reducer step handles one
// input (a tick, a key, a clock reading) and returns effects as values; the
// runtime performs them in a separate P step, and messages may arrive in
// between, as they may in the BEAM mailbox while the terminal runs. No other
// reducer step runs until the effects are performed: operator input and
// ticks are deferred while the Terminal is in `Performing`.
//
// The attachment worker is a keyed job. The reducer step that opens a
// session only allocates the attempt number, which is the job's key, and
// queues EFF_START (effect.StartJob); the runtime performs it, creating the
// frames inbox and the worker (job_runner.start_attach), and records the
// worker under the key in `jobs` (Model.running). Frames inboxes are named
// by an integer, which stands for a terminal-owned `Subject`, and
// `framesBox` stands for each inbox's mailbox together with what
// runtime.receive has already moved into its tui/buffered.Inbox; a message
// for an inbox that was never created or has been discarded is dropped,
// which is what a discarded `Subject` amounts to once nothing selects on it
// again.
//
// The job's own messages carry its key. runtime.hold admits a Prepared or
// an outcome into the candidate only when the candidate holds that key
// (attachment.admit), and drops it otherwise; a dropped Prepared has its
// socket closed and its frames inbox discarded (job_runner.dropped). The
// candidate learns its frames inbox from the Prepared it admits. Arrivals
// are admitted here as they arrive rather than at the next runtime.receive:
// the candidate changes only in a reducer step, so both see the same
// candidate. The reducer reads those buffers the way tick.update_tick and
// interaction.update_ready_key take from the buffered inboxes
// (buffered.take), and the discipline modelled here, read an inbox only
// while the model holds it, is what the code keeps by carrying each buffer
// inside the inbox value the adoption swap replaces. The per-step bounds the
// code applies to a top-up are not modelled: a step here takes everything
// that has arrived, which includes every ordering a bounded top-up allows.

type tArrived = (sock: machine, msg: tMsg);
type tPrep = (attempt: int, sock: machine, worker: machine, framesInbox: int);

// attachment.Status: Idle when `opening` is false, otherwise
// Opening(run, stage) for the job keyed `attempt`. The stage is Resolving
// until a Prepared is admitted, Published while `hasPrep` holds, and
// Connecting once `hasChan` holds. `framesInbox` is -1 until the Prepared
// names it. `outcomes` are the relay outcomes admitted and not yet settled.
// `ackTo` is the worker's acknowledgement subject.
type tCand = (
  opening: bool,
  attempt: int,
  hasPrep: bool,
  prep: tPrep,
  framesInbox: int,
  outcomes: seq[bool],
  hasChan: bool,
  chan: tChan,
  ackTo: machine,
  captured: bool
);

// tui/effect.Effect, restricted to the model: a channel output, the
// attachment outputs Acknowledge and Abandon, Discard, and the job
// effects StartJob and CancelJob for the attachment job.
enum tEffKind { EFF_OUT, EFF_ACK, EFF_ABANDON, EFF_DISCARD, EFF_START, EFF_CANCEL_JOB }
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

  // Model.running: the attachment jobs the runtime started and has not
  // heard the end of, by key, and the frames inbox it created for each.
  var jobs: map[int, machine];
  var jobFrames: map[int, int];

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

  // The terminal process has exited. Its mailbox is gone with it; the
  // guardian of a socket whose worker was cancelled at quit kills it.
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

  // runtime.hold for job.Published: attachment.admit takes one Prepared,
  // for the candidate's own key, while it is still Resolving. Anything else
  // is dropped, and job_runner.dropped closes its socket and discards the
  // frames inbox it names.
  fun arrivePrepared(p: tPreparedPayload) {
    if (cand.opening && cand.attempt == p.attempt && !cand.hasPrep && !cand.hasChan) {
      cand.hasPrep = true;
      cand.prep = (attempt = p.attempt, sock = p.sock, worker = p.worker, framesInbox = p.framesInbox);
      cand.framesInbox = p.framesInbox;
      wake();
    } else {
      announce ePreparedDropped, (sock = p.sock,);
      send p.sock, eShut, (sock = p.sock,);
      framesBox -= (p.framesInbox);
    }
  }

  // runtime.hold for job.Settled. The outcome is the job's last message, so
  // the runner forgets the job (job_runner.observed); it is admitted only
  // into the candidate holding its key.
  fun arriveOutcome(p: tOutcomePayload) {
    jobs -= (p.attempt);
    jobFrames -= (p.attempt);
    if (cand.opening && cand.attempt == p.attempt) {
      cand.outcomes += (sizeof(cand.outcomes), p.completed);
      wake();
    }
  }

  // -------------------------------------------------------------------------
  // Runtime: runtime.take and runtime.perform.
  // -------------------------------------------------------------------------

  // The adopted lane's outputs, then the candidate's, then the outbox: the
  // phase 1 collection. The code now keeps one queue in decision order; the
  // README's "What is modelled" says why the specs read the same either way.
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
    } else if (e.kind == EFF_START) {
      startJob(e.attempt);
    } else if (e.kind == EFF_CANCEL_JOB) {
      cancelJob(e.attempt);
    } else {
      framesBox -= (e.inbox);
    }
  }

  // job_runner.start_attach: the runtime creates the frames inbox and the
  // worker, and records both under the job's key.
  fun startJob(attempt: int) {
    var frames: int;
    frames = nextInbox;
    nextInbox = nextInbox + 1;
    framesBox[frames] = default(seq[tArrived]);
    jobs[attempt] = new AttachmentWorker((terminal = this, attempt = attempt, framesInbox = frames));
    jobFrames[attempt] = frames;
  }

  // job_runner.cancel: weft.cancel on the job's signal, and the frames
  // inbox the runtime created for it is discarded. A Prepared still in the
  // mailbox is dropped when it arrives, because the reducer cleared the
  // candidate in the step that cancelled the job.
  fun cancelJob(attempt: int) {
    if (attempt in jobs) {
      send jobs[attempt], eCancel, (attempt = attempt,);
      framesBox -= (jobFrames[attempt]);
    }
  }

  // attachment.cancel: close what the attempt holds and discard its frames
  // inbox. A candidate's channel performs what it had queued before its
  // close; an admitted Prepared that has no lane yet has its socket closed.
  fun cancelAttempt(s: tCand) {
    var c: tChan;
    var i: int;
    if (s.hasChan) {
      c = chanClose(s.chan);
      i = 0;
      while (i < sizeof(c.out)) {
        performOut(c.out[i]);
        i = i + 1;
      }
    } else if (s.hasPrep) {
      send s.prep.sock, eShut, (sock = s.prep.sock,);
    }
    if (s.framesInbox >= 0) {
      framesBox -= (s.framesInbox);
    }
  }

  // tui_model.emit_attachment for an Abandon: the job is cancelled by its
  // key first, then the attempt's own cleanup.
  fun abandon(s: tCand) {
    outbox += (sizeof(outbox), (kind = EFF_CANCEL_JOB, out = default(tOut), target = default(machine), attempt = s.attempt, status = idleCand(), inbox = 0));
    outbox += (sizeof(outbox), (kind = EFF_ABANDON, out = default(tOut), target = default(machine), attempt = s.attempt, status = s, inbox = 0));
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

  // inbound.drain_connection, taking from the buffered Model.inbox.
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
      abandon(cand);
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
  // first; a second attempt is refused while one is open. The step only
  // allocates the job's key and queues its start (tui_model.start_job and
  // attachment.opening); it creates no inbox and no worker.
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
    cand.framesInbox = -1;
    outbox += (sizeof(outbox), (kind = EFF_START, out = default(tOut), target = default(machine), attempt = attempt, status = idleCand(), inbox = 0));
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
    var completed: bool;
    var failedAdvance: bool;
    if (!cand.opening) {
      return;
    }
    if (!cand.hasChan && cand.hasPrep) {
      cand.hasChan = true;
      cand.hasPrep = false;
      cand.chan = chanStart(cand.prep.sock);
      cand.ackTo = cand.prep.worker;
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

    if (sizeof(cand.outcomes) > 0) {
      completed = cand.outcomes[0];
      cand.outcomes -= (0);
      if (completed) {
        adoptCandidate();
      } else {
        failCandidate(cand);
      }
    }
  }

  // attachment.failed, then candidate_outcome's Failed arm.
  fun failCandidate(status: tCand) {
    abandon(status);
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
