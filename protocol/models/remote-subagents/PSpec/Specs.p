// The properties the model checks. Each spec is named after the rule it
// encodes, and the comment above it cites where that rule lives. The rules come
// from protocol-change/084 and the design note
// docs/design-notes/remote-subagents.md, sections 8 and 14.

// A call site creates at most one child, however spawns, resends and run ends
// interleave. This is the adoption check of section 8.2: a resent `Spawn`
// derives the same name, finds its own cell and answers the same handle.
//
// A delegate session is what holds the child, so the rule is per session, and
// each Port holds its own. The session's deletion starts a new one, and a stale
// `Spawn` that reaches the remote after the release made a session for it is a
// new session's first spawn.
spec AtMostOneChildPerSite observes eCreated, eSessionDeleted {
  var created: map[machine, set[tSite]];

  start state Watching {
    on eCreated do (p: (site: tSite, child: tChild, run: int, owner: int, at: machine)) {
      if (!(p.at in created)) {
        created[p.at] = default(set[tSite]);
      }
      assert !(p.site in created[p.at]), format("call site {0} created a second child", p.site);
      created[p.at] += (p.site);
    }

    on eSessionDeleted do (at: machine) {
      created[at] = default(set[tSite]);
    }
  }
}

// A call site's children are all on one orchestrator (phase 4). A spawn is
// resent until it is answered and never sent to another orchestrator
// (`remote_spawn`), because the adoption that makes a resend safe is one
// orchestrator's: a second orchestrator has no record of the first child and
// would make another. The stub records the orchestrator before the first send,
// and every resend and join reads it from there.
spec OneOrchestratorPerSite observes eCreated {
  var placed: map[tSite, machine];

  start state Watching {
    on eCreated do (p: (site: tSite, child: tChild, run: int, owner: int, at: machine)) {
      if (p.site in placed) {
        assert placed[p.site] == p.at, format("call site {0} created children on two orchestrators", p.site);
      }
      placed[p.site] = p.at;
    }
  }
}

// The remote answers a call site only with the child that call site minted.
// Adoption compares `minted_by` and not the name alone (section 8.2); two call
// sites that derive one name must not share a child.
spec OwnChildOnly observes eCreated, eAnswered {
  var madeBy: map[tChild, tSite];

  start state Watching {
    on eCreated do (p: (site: tSite, child: tChild, run: int, owner: int, at: machine)) {
      madeBy[p.child] = p.site;
    }

    on eAnswered do (p: (site: tSite, child: tChild)) {
      assert p.child in madeBy && madeBy[p.child] == p.site, format("call site {0} was answered with child {1}, which another call site minted", p.site, p.child);
    }
  }
}

// A stub that names a child keeps naming it. Every answer the laptop writes for
// a call site, from the effect process or from the drainer, names one child.
spec AnswerIsStable observes eStubSpawnedAs {
  var named: map[tSite, tChild];

  start state Watching {
    on eStubSpawnedAs do (p: (site: tSite, child: tChild)) {
      if (p.site in named) {
        assert named[p.site] == p.child, format("call site {0} was named child {1} and then child {2}", p.site, named[p.site], p.child);
      }
      named[p.site] = p.child;
    }
  }
}

// A join never reports a result for a different child. The drainer settles a
// stub only from a `Joined` that names the stub's own child, and the state it
// reports is the state the remote gave that child.
spec JoinReportsOwnChild observes eCreated, eChildTerminal, eReported {
  var madeBy: map[tChild, tSite];
  var ended: map[tChild, tChildState];

  start state Watching {
    on eCreated do (p: (site: tSite, child: tChild, run: int, owner: int, at: machine)) {
      madeBy[p.child] = p.site;
    }

    on eChildTerminal do (p: (child: tChild, st: tChildState)) {
      ended[p.child] = p.st;
    }

    on eReported do (p: (site: tSite, child: tChild, st: tChildState)) {
      assert p.child in madeBy && madeBy[p.child] == p.site, format("call site {0} was told the result of child {1}, which another call site minted", p.site, p.child);
      assert p.child in ended && ended[p.child] == p.st, format("child {0} was reported in a state it did not reach", p.child);
    }
  }
}

// A child reaches a terminal state once. The deadline tick, a run end, a
// finish and a restart each stop only a child that is still running.
spec TerminalOnce observes eChildTerminal {
  var seen: set[tChild];

  start state Watching {
    on eChildTerminal do (p: (child: tChild, st: tChildState)) {
      assert !(p.child in seen), format("child {0} reached a terminal state twice", p.child);
      seen += (p.child);
    }
  }
}

// Once the remote has handled a `RunEnded`, no spawn for that run creates a
// child (the ended fence, section 8.3). A resend that adopts a child created
// before the run ended is not a creation.
spec NoSpawnUnderEndedRun observes eRunEndedHandled, eCreated, eSessionDeleted {
  var ended: set[int];

  start state Watching {
    on eRunEndedHandled do (p: (run: int, stillRunning: int)) {
      ended += (p.run);
    }

    on eSessionDeleted do (at: machine) {
      ended = default(set[int]);
    }

    on eCreated do (p: (site: tSite, child: tChild, run: int, owner: int, at: machine)) {
      assert !(p.run in ended), format("call site {0} created child {1} under run {2}, which had ended", p.site, p.child, p.run);
    }
  }
}

// A `RunEnded` stops every child attached to the run (`reap_run`).
spec EndedRunChildrenStop observes eRunEndedHandled {
  start state Watching {
    on eRunEndedHandled do (p: (run: int, stillRunning: int)) {
      assert p.stillRunning == 0, format("{0} children of run {1} were still running after its end", p.stillRunning, p.run);
    }
  }
}

// Every call site the parent made durable is eventually answered, by a handle
// or a refusal. A dropped connection is repaired by sending again, an aborted
// effect process by the drainer, and a restarted remote answers from its store,
// so bounded faults delay the answer and cannot lose it. P reports a violation
// when a run ends with the monitor in the hot state.
spec EveryStubAnswered observes eStubRequested, eStubDone {
  var pending: set[tSite];

  start cold state Quiet {
    on eStubRequested do (site: tSite) {
      pending += (site);
      goto Waiting;
    }
  }

  hot state Waiting {
    on eStubRequested do (site: tSite) {
      pending += (site);
    }

    on eStubDone do (site: tSite) {
      pending -= (site);
      if (sizeof(pending) == 0) {
        goto Quiet;
      }
    }
  }
}

// Every child the remote created reaches a terminal state once the deadlines
// pass: the tick stops it, it finishes, or a restart ends its run. This is the
// bound of section 8.3, and it holds with no message from the laptop.
spec EveryChildTerminal observes eCreated, eChildTerminal {
  var live: set[tChild];

  start cold state Quiet {
    on eCreated do (p: (site: tSite, child: tChild, run: int, owner: int, at: machine)) {
      live += (p.child);
      goto Waiting;
    }
  }

  hot state Waiting {
    on eCreated do (p: (site: tSite, child: tChild, run: int, owner: int, at: machine)) {
      live += (p.child);
    }

    on eChildTerminal do (p: (child: tChild, st: tChildState)) {
      live -= (p.child);
      if (sizeof(live) == 0) {
        goto Quiet;
      }
    }
  }
}

// A `Release` leaves no running child in the session it releases, and no child
// is made in that session afterwards. The fence is the released phase the holder
// writes before it stops the children (`delegate/released`), and `admit_run`
// reads it on the create path: a `Spawn` that overtakes the `Release` is refused
// when the session is already releasing, and one that came first is a child the
// release stops.
spec ReleasedSessionHasNoRunningChild observes eReleaseHandled, eChildIn {
  var released: set[(machine, int)];

  start state Watching {
    on eReleaseHandled do (p: (gen: int, stopped: int, stillRunning: int, at: machine, depth: int)) {
      assert p.stillRunning == 0, format("{0} children were still running after the release of session {1}", p.stillRunning, p.gen);
      released += ((p.at, p.gen));
    }

    on eChildIn do (p: (child: tChild, gen: int, at: machine)) {
      assert !((p.at, p.gen) in released), format("child {0} was made in session {1}, which had been released", p.child, p.gen);
    }
  }
}

// A `Release` makes no session. It is sent to an orchestrator that may hold
// nothing for the parent, and a session made only to be deleted would cost an
// executor scope and count against the spawner's `max_sessions`.
spec ReleaseMakesNoSession observes eSessionMade {
  start state Watching {
    on eSessionMade do (by: tKind) {
      assert by != K_RELEASE, "a release made a delegate session";
    }
  }
}

// Every release row a spawner writes is eventually answered, the laptop's to the
// box and the box's delegate session's to a third orchestrator. Only an answer
// settles the row: an unreachable call leaves it, and the next pass sends it
// again, so bounded faults delay the answer and cannot lose it.
spec EveryReleaseIsTold observes eReleaseWritten, eReleaseTold {
  var owed: set[(machine, machine)];

  start cold state Quiet {
    on eReleaseWritten do (p: (who: machine, port: machine)) {
      owed += ((p.who, p.port));
      goto Waiting;
    }
  }

  hot state Waiting {
    on eReleaseWritten do (p: (who: machine, port: machine)) {
      owed += ((p.who, p.port));
    }

    on eReleaseTold do (p: (who: machine, port: machine)) {
      owed -= ((p.who, p.port));
      if (sizeof(owed) == 0) {
        goto Quiet;
      }
    }
  }
}

// A released session's descendants on every box end (phase 4). When the box
// deletes a released session, once its slot has drained (`eCascadeDue`), its
// children's children are on third orchestrators that only its stubs name. The
// deletion must leave a row for each of them (the cascade, `eCascadeWritten`),
// and each row must be answered by the third orchestrator, whose own release
// stops every running child there. So the monitor is hot from the box's deletion
// until the cascade has been written and every orchestrator it names has
// answered, and a third orchestrator's release that left a child running fails
// at once. A grandchild that a spawn already in flight makes after the third
// orchestrator's release is bounded by its deadline, as at depth 1, and is not a
// descendant this release could reach.
spec ReleasedDescendantsEnd observes eCascadeDue, eReleaseHandled, eCascadeWritten, eReleaseTold {
  var awaiting: int;
  var pending: set[machine];

  start cold state Quiet {
    on eCascadeDue do {
      awaiting = awaiting + 1;
      goto Waiting;
    }

    on eReleaseHandled do (p: (gen: int, stopped: int, stillRunning: int, at: machine, depth: int)) {
      noneLeft(p.stillRunning, p.depth);
    }

    on eCascadeWritten do (owed: set[machine]) {
      awaiting = awaiting - 1;
    }

    on eReleaseTold do (p: (who: machine, port: machine)) {
      pending -= (p.port);
    }
  }

  hot state Waiting {
    on eCascadeDue do {
      awaiting = awaiting + 1;
    }

    on eReleaseHandled do (p: (gen: int, stopped: int, stillRunning: int, at: machine, depth: int)) {
      noneLeft(p.stillRunning, p.depth);
    }

    on eCascadeWritten do (owed: set[machine]) {
      var p: machine;
      awaiting = awaiting - 1;
      foreach (p in owed) {
        pending += (p);
      }
      if (awaiting <= 0 && sizeof(pending) == 0) {
        goto Quiet;
      }
    }

    on eReleaseTold do (p: (who: machine, port: machine)) {
      pending -= (p.port);
      if (awaiting <= 0 && sizeof(pending) == 0) {
        goto Quiet;
      }
    }
  }

  fun noneLeft(stillRunning: int, depth: int) {
    assert depth == 1 || stillRunning == 0, format("{0} grandchildren were still running after their orchestrator's release", stillRunning);
  }
}

// A spawner sends no spawn that makes a child after its own `Release` reached
// that orchestrator (phase 4). Its drainer, which sends both, writes the release
// row only when nothing of the session is left to resend a spawn: the laptop's
// stubs go with the deleted parent session, and the box's delegate session's
// rows are written in the turn that deletes it after its slot drained. Both
// come from the same process, which delivers in order. A spawn from the effect
// process that was still asking when the session went is another sender, may
// arrive after the release, and is bounded by its deadline; this spec does not
// count it.
spec NoSpawnAfterOwnRelease observes eReleaseFrom, eAdmittedFrom {
  var released: set[(machine, machine)];

  start state Watching {
    on eReleaseFrom do (p: (at: machine, src: machine)) {
      released += ((p.at, p.src));
    }

    on eAdmittedFrom do (p: (at: machine, src: machine)) {
      assert !((p.at, p.src) in released), "a spawner's spawn made a child after its own release reached the orchestrator";
    }
  }
}


// A mail steers the parent at most once, however often the remote sends it. The
// laptop stores the receipt in the commit that steers (`remote-mail/{id}`), so a
// resend after a lost reply, a break or a restart is answered from the receipt.
spec UpwardAtMostOnce observes eSteered {
  var steered: set[int];

  start state Watching {
    on eSteered do (id: int) {
      assert !(id in steered), format("mail {0} steered the parent twice", id);
      steered += (id);
    }
  }
}

// A mail steers only a parent that has a run open. A finished parent is never
// woken for a child's message, so a delivery that finds it idle is declined and
// the refusal is the receipt (`BusyOnly`, not `MayWake`).
spec UpwardOnlyIntoOpenRun observes eRunClosed, eSteered {
  var closed: bool;

  start state Watching {
    on eRunClosed do {
      closed = true;
    }

    on eSteered do (id: int) {
      assert !closed, format("mail {0} steered a parent whose run had ended", id);
    }
  }
}

// Every mail the remote writes is eventually answered, or discarded with the
// session that held it. Only an answer settles a row, and `MAIL_NOT_OPEN` is not
// one, so a connection that breaks or a parent session that is closed delays the
// answer and cannot lose it. This holds under the fair reconnection the link
// keeper assumes and a parent session that is eventually opened; without them no
// remote could promise it. P reports a violation when a run ends in the hot
// state.
spec EveryMailAnswered observes eMailQueued, eMailSettled {
  var pending: set[int];

  start cold state Quiet {
    on eMailQueued do (id: int) {
      pending += (id);
      goto Waiting;
    }
  }

  hot state Waiting {
    on eMailQueued do (id: int) {
      pending += (id);
    }

    on eMailSettled do (id: int) {
      pending -= (id);
      if (sizeof(pending) == 0) {
        goto Quiet;
      }
    }
  }
}

// A mail about a child the parent holds a stub for is never answered unknown.
// The stub is written before the first `Spawn` leaves and records the child's
// name, so mail finds it in any state, `Requested` included, and the host keys on
// the name and never on a handle that exists only after the `Spawn` is answered.
spec MailFindsItsStub observes eUnknownAnswered {
  start state Watching {
    on eUnknownAnswered do (p: (site: tSite, hasStub: bool)) {
      assert !p.hasStub, format("mail from call site {0} was answered unknown while the parent holds its stub", p.site);
    }
  }
}
