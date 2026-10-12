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
machine Port {
  var wire: machine;
  var children: map[tChild, tChildRec];
  var byName: map[int, tChild];
  var fence: set[int];
  var next: int;
  var clockPast: bool;

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
    announce eCreated, (site = m.site, child = c, run = m.run, owner = m.owner);
    announce eAnswered, (site = m.site, child = c);
    answer(m, K_SPAWNED, c, CS_RUNNING);
    if (clockPast) {
      send this, eTick;
    }
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
    send wire, eSend, (sender = this, msg = (kind = kind, src = this, dest = m.src, site = m.site, child = c, st = s, run = m.run, owner = m.owner));
  }
}
