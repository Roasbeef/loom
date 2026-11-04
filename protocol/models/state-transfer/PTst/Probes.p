// Reachability probes. Each probe asserts that one situation never happens, so a
// probe "failing" is the checker finding a witness that the model reaches the
// situation. They guard against a vacuous model: a spec that passes only because
// the situation it constrains is unreachable proves nothing. Every tcProbe* case
// is expected to report a bug.

// A pass resumed at an offset past zero: the receiver held a prefix, and the
// sender asked and continued from it instead of beginning again.
spec ProbeResumed observes eResumed {
  start state Watching {
    on eResumed do (offset: int) {
      assert false, "witness: a pass resumed at a non-zero offset";
    }
  }
}

// A restart left a non-empty half-written file shorter than it was.
spec ProbeTruncated observes eTruncated {
  start state Watching {
    on eTruncated do {
      assert false, "witness: a restart shortened a half-written file";
    }
  }
}

// A transfer was refused for good, because the bytes are not the described state.
spec ProbeDeclined observes eDeclined {
  start state Watching {
    on eDeclined do {
      assert false, "witness: a forged bundle was refused at the last piece";
    }
  }
}
