// Reachability probes. Each probe asserts that one situation never happens, so
// a probe "failing" is the checker finding a witness that the model reaches the
// situation. They guard against a vacuous model: a spec that passes only
// because the situation it constrains is unreachable proves nothing. Every
// tcProbe* case is expected to report a bug.

// A `Run` sent again after a dropped connection joined the run that was still
// going.
spec ProbeResendJoinsLiveRun observes eJoined {
  start state Watching {
    on eJoined do (p: (key: tKey, resent: bool)) {
      assert !p.resent, "witness: a re-sent Run joined a live run";
    }
  }
}

// A dead open's `Run` reached the host after the next open's attach and was
// refused for its token.
spec ProbeStaleRunRefused observes eStaleRun {
  start state Watching {
    on eStaleRun do (key: tKey) {
      assert false, "witness: a Run with a stale token reached the host";
    }
  }
}

// A `Run` arrived for a key whose fence was already stored, and found it taken.
spec ProbeFenceBeforeRun observes eFoundFence {
  start state Watching {
    on eFoundFence do (key: tKey) {
      assert false, "witness: a Run found the key already fenced";
    }
  }
}

// A connection drop left the run going, it finished with nobody waiting, and a
// re-sent `Run` read its stored outcome.
spec ProbeResendReadsStoredOutcome observes eStoredAnswer {
  start state Watching {
    on eStoredAnswer do (p: (key: tKey, resent: bool)) {
      assert !p.resent, "witness: a re-sent Run read the stored outcome";
    }
  }
}

// A recovery fenced a key that no one had run, and reported it as not started.
spec ProbeRecoveryFenced observes eFenced {
  start state Watching {
    on eFenced do (key: tKey) {
      assert false, "witness: recovery fenced a missing key";
    }
  }
}

// A ledger row became unknown, whether by a cancelled run or by a restart.
spec ProbeKeyUnknown observes eUnknown {
  start state Watching {
    on eUnknown do (key: tKey) {
      assert false, "witness: a key became unknown";
    }
  }
}

// A live run was cancelled because its last waiter was killed.
spec ProbeAbortCancels observes eCancelled {
  start state Watching {
    on eCancelled do (p: (key: tKey, noconn: bool)) {
      assert false, "witness: a killed waiter cancelled a live run";
    }
  }
}
