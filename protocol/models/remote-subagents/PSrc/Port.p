// The remote orchestrator and the delegate session's Agency holder
// (`remote/orchestrator_port.gleam`, `agency.gleam`).
//
// Everything in `children`, `byName` and `fence` is the delegate session's
// store, which survives a restart of the VM. The port's memory holds nothing
// else.
//
// A `Spawn` is admitted in the order the code takes (design note, section 8.2):
//
// | The session holds | The port does |
// |---|---|
// | a child under the derived name, minted by this call site | adopts it: answers its handle and creates nothing |
// | a child under the derived name, minted by another call site | refuses the spawn |
// | no child under the name, and the ended fence set for the run | refuses the spawn |
// | no child under the name | creates the child and answers its handle |
//
// The fence is read after the adoption check, so a resend that finds the child
// its call site already made is answered with that child whether or not the
// run has ended.
//
// A child leaves `CS_RUNNING` in one of four ways, each announced as
// `eChildTerminal` once: it finishes (`eFinishOne`, the environment choosing
// which), the tick stops it after its deadline, a `RunEnded` stops it when it is
// attached to that run, or the remote restarts and its run is lost. A restart
// arms no tick, because a delegate session is only reopened by the next `Spawn`
// or `Join`, and nothing is running in a closed one (design note, section 8.3).
//
// The parent session itself can be deleted, and then the laptop sends
// `Release`. The session has three phases (`tSession`). A `Release` for a parent
// with no session answers zero and makes nothing: it is the one message here
// that must not create a session, because it exists to delete one. A `Release`
// for an open session writes the released fence, stops every running child
// whoever owns it, and answers how many it stopped. From then on the session
// refuses every spawn. The registry deletes it when its slot drains, which the
// model leaves to the environment (`eSlotDrained`), and deleting it removes the
// children, the fences and everything else stored under it. The message that
// makes the next session for the parent is a `Spawn` or a `RunEnded`, as in the
// code. A repeat of `Release` stops nothing more and answers zero.
//
// A running child can mail its parent (`eUpward`). The mail is a row in the
// session's outbox, written before anything is sent and rung to the drainer. A
// pass sends every row that is not answered, and the wire sends it only while
// the connection is up, so a laptop that is away costs nothing. The remote never
// settles a row on its own account: only the laptop's answer does, whether it is
// a receipt or a refusal that will not change. `MAIL_NOT_OPEN` is the one answer
// that leaves the row, and the next pass asks again. The outbox is stored in the
// session, so it survives a restart of the VM and is deleted with the session.
machine Port {
  var wire: machine;
  var children: map[tChild, tChildRec];
  var byName: map[int, tChild];
  var fence: set[int];
  var next: int;
  var clockPast: bool;
  var phase: tSession;
  var gen: int;
  var laptop: machine;
  var outbox: map[int, tRow];
  var nextMail: int;

  start state Up {
    entry (w: machine) {
      wire = w;
    }

    on eNet do (m: tMsg) {
      if (m.kind == K_SPAWN) {
        admit(m);
      } else if (m.kind == K_JOIN) {
        join(m);
      } else if (m.kind == K_RUN_ENDED) {
        runEnded(m.run);
      } else if (m.kind == K_RELEASE) {
        release(m);
      } else if (m.kind == K_MAILED) {
        mailed(m);
      }
    }

    on eLaptop do (l: machine) {
      laptop = l;
    }

    on eUpward do {
      upward();
    }

    on eMailPass do {
      mailPass();
    }

    on eSlotDrained do {
      if (phase == SS_RELEASING) {
        deleteSession();
      }
    }

    on eFinishOne do {
      finishOne();
    }

    on eDeadlineAll do {
      clockPast = true;
      markOverdue();
      send this, eTick;
    }

    on eTick do {
      reapOverdue();
    }

    on eRestart do {
      loseRuns();
    }
  }

  // Admission of one `Spawn`.
  fun admit(m: tMsg) {
    var name: int;
    var c: tChild;
    if (phase == SS_NONE) {
      makeSession(K_SPAWN);
    }
    if (phase == SS_RELEASING) {
      announce eRefused, (site = m.site, reason = 2);
      answer(m, K_REFUSED, 0, CS_RUNNING);
      return;
    }
    name = nameOf(m.site);
    if (name in byName) {
      c = byName[name];
      if (children[c].mintedBy == m.site) {
        announce eAnswered, (site = m.site, child = c);
        answer(m, K_SPAWNED, c, children[c].st);
      } else {
        announce eRefused, (site = m.site, reason = 0);
        answer(m, K_REFUSED, c, children[c].st);
      }
      return;
    }
    if (m.run in fence) {
      announce eRefused, (site = m.site, reason = 1);
      answer(m, K_REFUSED, 0, CS_RUNNING);
      return;
    }
    c = next;
    next = next + 1;
    children[c] = (mintedBy = m.site, run = m.run, owner = m.owner, st = CS_RUNNING, overdue = clockPast);
    byName[name] = c;
    announce eChildIn, (child = c, gen = gen);
    announce eCreated, (site = m.site, child = c, run = m.run, owner = m.owner);
    announce eAnswered, (site = m.site, child = c);
    answer(m, K_SPAWNED, c, CS_RUNNING);
    if (clockPast) {
      send this, eTick;
    }
  }

  // A running child sends its parent a message: the row is written and the
  // drainer is rung. With no child running there is no one to send it.
  fun upward() {
    var c: tChild;
    var cs: seq[tChild];
    var running: seq[tChild];
    var id: int;
    cs = keys(children);
    foreach (c in cs) {
      if (children[c].st == CS_RUNNING) {
        running += (sizeof(running), c);
      }
    }
    if (sizeof(running) == 0) {
      return;
    }
    c = choose(running);
    id = nextMail;
    nextMail = nextMail + 1;
    outbox[id] = (site = children[c].mintedBy, child = c, answered = false);
    announce eMailQueued, id;
    send this, eMailPass;
  }

  // One drainer pass: every row that has no answer is sent.
  fun mailPass() {
    var id: int;
    var ids: seq[int];
    ids = keys(outbox);
    foreach (id in ids) {
      if (!outbox[id].answered) {
        send wire, eSendUp, (sender = this, msg = (kind = K_MAIL, src = this, dest = laptop, site = outbox[id].site, child = outbox[id].child, st = CS_RUNNING, run = 0, owner = -1, id = id, code = MAIL_DELIVERED));
      }
    }
  }

  // The laptop's answer to a mail. Every answer settles the row but one.
  fun mailed(m: tMsg) {
    if (!(m.id in outbox) || outbox[m.id].answered) {
      return;
    }
    if (m.code == MAIL_NOT_OPEN) {
      return;
    }
    outbox[m.id].answered = true;
    announce eMailSettled, m.id;
  }

  // A zero-window `Join`: where the named child stands.
  fun join(m: tMsg) {
    if (m.child in children) {
      answer(m, K_JOINED, m.child, children[m.child].st);
    }
  }

  // `RunEnded`: the holder writes the fence, then stops every child attached to
  // the run.
  fun runEnded(run: int) {
    var c: tChild;
    var cs: seq[tChild];
    var running: int;
    if (phase == SS_NONE) {
      makeSession(K_RUN_ENDED);
    }
    fence += (run);
    cs = keys(children);
    foreach (c in cs) {
      if (children[c].owner == run && children[c].st == CS_RUNNING) {
        end(c, CS_STOPPED);
      }
    }
    foreach (c in cs) {
      if (children[c].owner == run && children[c].st == CS_RUNNING) {
        running = running + 1;
      }
    }
    announce eRunEndedHandled, (run = run, stillRunning = running);
  }

  // A session for the parent is made by the message that first needs one.
  fun makeSession(by: tKind) {
    phase = SS_OPEN;
    announce eSessionMade, by;
  }

  // `Release`: the holder writes the released fence first, and stops every
  // running child second. A parent with no session has nothing to release, and
  // nothing is made for it. The registry then deletes the session when its slot
  // drains, which the environment decides (`eSlotDrained`).
  fun release(m: tMsg) {
    var c: tChild;
    var cs: seq[tChild];
    var stopped: int;
    var running: int;
    if (phase == SS_NONE) {
      announce eReleaseNoSession;
      answer(m, K_RELEASED, 0, CS_RUNNING);
      return;
    }
    phase = SS_RELEASING;
    cs = keys(children);
    foreach (c in cs) {
      if (children[c].st == CS_RUNNING) {
        end(c, CS_STOPPED);
        stopped = stopped + 1;
      }
    }
    foreach (c in cs) {
      if (children[c].st == CS_RUNNING) {
        running = running + 1;
      }
    }
    announce eReleaseHandled, (gen = gen, stopped = stopped, stillRunning = running);
    answer(m, K_RELEASED, stopped, CS_RUNNING);
  }

  // The slot drained and the registry deletes the session. Whatever is still
  // running dies with it, and everything stored under it goes.
  fun deleteSession() {
    var id: int;
    var ids: seq[int];
    loseRuns();
    ids = keys(outbox);
    foreach (id in ids) {
      if (!outbox[id].answered) {
        announce eMailSettled, id;
      }
    }
    outbox = default(map[int, tRow]);
    children = default(map[tChild, tChildRec]);
    byName = default(map[int, tChild]);
    fence = default(set[int]);
    phase = SS_NONE;
    gen = gen + 1;
    announce eSessionDeleted;
  }

  // Marks every child running now as past its deadline.
  fun markOverdue() {
    var c: tChild;
    var cs: seq[tChild];
    cs = keys(children);
    foreach (c in cs) {
      children[c].overdue = true;
    }
  }

  // The tick: `reap_overdue` stops every running child past its deadline.
  fun reapOverdue() {
    var c: tChild;
    var cs: seq[tChild];
    cs = keys(children);
    foreach (c in cs) {
      if (children[c].st == CS_RUNNING && children[c].overdue) {
        end(c, CS_STOPPED);
      }
    }
  }

  // The environment picks one running child whose run ends on its own.
  fun finishOne() {
    var c: tChild;
    var cs: seq[tChild];
    var running: seq[tChild];
    cs = keys(children);
    foreach (c in cs) {
      if (children[c].st == CS_RUNNING) {
        running += (sizeof(running), c);
      }
    }
    if (sizeof(running) > 0) {
      end(choose(running), CS_SETTLED);
    }
  }

  // A restart of the VM ends every run that was going.
  fun loseRuns() {
    var c: tChild;
    var cs: seq[tChild];
    cs = keys(children);
    foreach (c in cs) {
      if (children[c].st == CS_RUNNING) {
        end(c, CS_LOST);
      }
    }
  }

  // A child reaches a terminal state, exactly once.
  fun end(c: tChild, s: tChildState) {
    children[c].st = s;
    announce eChildTerminal, (child = c, st = s);
  }

  fun answer(m: tMsg, kind: tKind, c: tChild, s: tChildState) {
    send wire, eSend, (sender = this, msg = (kind = kind, src = this, dest = m.src, site = m.site, child = c, st = s, run = m.run, owner = m.owner, id = 0, code = MAIL_DELIVERED));
  }
}
