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
    on eReleaseHandled do (p: (gen: int, stopped: int, stillRunning: int)) {
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
    on eSessionDeleted do {
      assert false, "witness: a released session was deleted";
    }
  }
}
