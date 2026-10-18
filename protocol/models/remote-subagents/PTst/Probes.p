// Reachability probes. Each probe asserts that one situation never happens, so a
// probe "failing" is the checker finding a witness that the model reaches the
// situation. They guard against a vacuous model: a spec that passes only because
// the situation it constrains is unreachable proves nothing. Every tcProbe* case
// is expected to report a bug.

// A resent `Spawn` was answered a second time for a call site, which is the
// adoption path: the remote found the child the site already made.
spec ProbeAdoption observes eAnswered {
  var answered: set[tSite];

  start state Watching {
    on eAnswered do (p: (site: tSite, child: tChild)) {
      assert !(p.site in answered), "witness: a call site was answered twice, by adoption";
      answered += (p.site);
    }
  }
}

// A call site that derives another site's name was refused.
spec ProbeCollisionRefused observes eRefused {
  start state Watching {
    on eRefused do (p: (site: tSite, reason: int)) {
      assert p.reason != 0, "witness: a spawn was refused for a name another call site holds";
    }
  }
}

// A spawn arrived after its run ended and was refused by the fence.
spec ProbeFenceRefused observes eRefused {
  start state Watching {
    on eRefused do (p: (site: tSite, reason: int)) {
      assert p.reason != 1, "witness: a spawn was refused by the ended fence";
    }
  }
}

// A restart of the remote ended a child's run.
spec ProbeChildLost observes eChildTerminal {
  start state Watching {
    on eChildTerminal do (p: (child: tChild, st: tChildState)) {
      assert p.st != CS_LOST, "witness: a restart ended a child's run";
    }
  }
}

// A child was stopped, by the tick or by a run end.
spec ProbeChildStopped observes eChildTerminal {
  start state Watching {
    on eChildTerminal do (p: (child: tChild, st: tChildState)) {
      assert p.st != CS_STOPPED, "witness: a child was stopped";
    }
  }
}

// The drainer settled a stub from a join.
spec ProbeJoinSettled observes eReported {
  start state Watching {
    on eReported do (p: (site: tSite, child: tChild, st: tChildState)) {
      assert false, "witness: a join settled a stub";
    }
  }
}

// A `Release` stopped a running child.
spec ProbeReleaseStopped observes eReleaseHandled {
  start state Watching {
    on eReleaseHandled do (p: (gen: int, stopped: int, stillRunning: int, at: machine, depth: int)) {
      assert p.stopped == 0, "witness: a release stopped a running child";
    }
  }
}

// A spawn that overtook the `Release` was refused by the released fence.
spec ProbeReleaseRefusedSpawn observes eRefused {
  start state Watching {
    on eRefused do (p: (site: tSite, reason: int)) {
      assert p.reason != 2, "witness: a spawn was refused by the released fence";
    }
  }
}

// A `Release` found no session and made none: it overtook the first spawn, or
// repeated after the session was deleted.
spec ProbeReleaseFoundNoSession observes eReleaseNoSession {
  start state Watching {
    on eReleaseNoSession do {
      assert false, "witness: a release found no session";
    }
  }
}

// The registry deleted a released session after its slot drained.
spec ProbeSessionDeleted observes eSessionDeleted {
  start state Watching {
    on eSessionDeleted do (at: machine) {
      assert false, "witness: a released session was deleted";
    }
  }
}

// A mail steered the parent.
spec ProbeMailDelivered observes eSteered {
  start state Watching {
    on eSteered do (id: int) {
      assert false, "witness: a mail steered the parent";
    }
  }
}

// A mail found the parent idle and was declined.
spec ProbeMailDeclined observes eMailDeclined {
  start state Watching {
    on eMailDeclined do {
      assert false, "witness: a mail was declined by an idle parent";
    }
  }
}

// A mail found the parent session closed and was asked about again.
spec ProbeMailNotOpen observes eMailNotOpen {
  start state Watching {
    on eMailNotOpen do {
      assert false, "witness: a mail found the parent session closed";
    }
  }
}

// A mail that had a receipt was sent again and answered from the receipt.
spec ProbeMailRepeated observes eMailRepeated {
  start state Watching {
    on eMailRepeated do {
      assert false, "witness: a resent mail was answered from its receipt";
    }
  }
}

// A mail arrived while the parent's stub for its child was still `Requested`.
spec ProbeMailForRequested observes eMailForRequested {
  start state Watching {
    on eMailForRequested do {
      assert false, "witness: a mail arrived before the answer to its spawn";
    }
  }
}

// A child on the box started a child of its own on a third orchestrator.
spec ProbeGrandchildMade observes eCreated {
  start state Watching {
    on eCreated do (p: (site: tSite, child: tChild, run: int, owner: int, at: machine)) {
      assert p.site < 100, "witness: a grandchild was made on a third orchestrator";
    }
  }
}

// A release of the box's session owed a third orchestrator a release.
spec ProbeCascadeOwed observes eCascadeWritten {
  start state Watching {
    on eCascadeWritten do (owed: set[machine]) {
      assert sizeof(owed) == 0, "witness: a release cascaded to a third orchestrator";
    }
  }
}

// The cascade reached a third orchestrator and stopped a grandchild running there.
spec ProbeGrandchildReleased observes eReleaseHandled {
  start state Watching {
    on eReleaseHandled do (p: (gen: int, stopped: int, stillRunning: int, at: machine, depth: int)) {
      assert p.depth != 2 || p.stopped == 0, "witness: a cascaded release stopped a grandchild";
    }
  }
}
