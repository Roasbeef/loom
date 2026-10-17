// The properties the model checks. Each spec is named after the rule it
// encodes, and the comment above it cites where that rule lives. The rules come
// from protocol-change/084 and the design note
// docs/design-notes/remote-subagents.md, sections 8 and 14.

// A call site creates at most one child, however spawns, resends and run ends
// interleave. This is the adoption check of section 8.2: a resent `Spawn`
// derives the same name, finds its own cell and answers the same handle.
spec AtMostOneChildPerSite observes eCreated {
  var created: set[tSite];

  start state Watching {
    on eCreated do (p: (site: tSite, child: tChild, run: int, owner: int)) {
      assert !(p.site in created), format("call site {0} created a second child", p.site);
      created += (p.site);
    }
  }
}

// The remote answers a call site only with the child that call site minted.
// Adoption compares `minted_by` and not the name alone (section 8.2); two call
// sites that derive one name must not share a child.
spec OwnChildOnly observes eCreated, eAnswered {
  var madeBy: map[tChild, tSite];

  start state Watching {
    on eCreated do (p: (site: tSite, child: tChild, run: int, owner: int)) {
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
    on eCreated do (p: (site: tSite, child: tChild, run: int, owner: int)) {
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
spec NoSpawnUnderEndedRun observes eRunEndedHandled, eCreated {
  var ended: set[int];

  start state Watching {
    on eRunEndedHandled do (p: (run: int, stillRunning: int)) {
      ended += (p.run);
    }

    on eCreated do (p: (site: tSite, child: tChild, run: int, owner: int)) {
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
    on eCreated do (p: (site: tSite, child: tChild, run: int, owner: int)) {
      live += (p.child);
      goto Waiting;
    }
  }

  hot state Waiting {
    on eCreated do (p: (site: tSite, child: tChild, run: int, owner: int)) {
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
