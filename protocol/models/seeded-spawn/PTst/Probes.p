// Reachability probes. Each probe asserts that one situation never happens, so a
// probe "failing" is the checker finding a witness that the model reaches the
// situation. They guard against a vacuous model: a spec that passes only because
// the situation it constrains is unreachable proves nothing. Every tcProbe* case
// is expected to report a bug.

// An apply request arrived at a tree that already held the tip: a retried land
// after a lost reply to the first apply, or a resend the first one overlapped.
spec ProbeApplyRetried observes eApplyRepeated {
  start state Watching {
    on eApplyRepeated do {
      assert false, "witness: an apply was retried against a tree that already held the seed";
    }
  }
}

// The orchestrator restarted after the executor confirmed the apply and before
// the child's first turn.
spec ProbeRestartBetweenApplyAndSpawn observes eCrashBetween {
  start state Watching {
    on eCrashBetween do {
      assert false, "witness: a restart between the apply and the spawn";
    }
  }
}

// The child's commits were captured after the executor restarted.
spec ProbeReturnAfterExecRestart observes eCapturedAfterRestart {
  start state Watching {
    on eCapturedAfterRestart do {
      assert false, "witness: a capture served after an executor restart";
    }
  }
}

// An apply was refused by a fence that moved on, and the spawn went on to end.
spec ProbeStaleFence observes eTransient {
  start state Watching {
    on eTransient do (why: tWhy) {
      assert why != W_STALE, "witness: an apply was refused as stale";
    }
  }
}

// A seeded spawn was refused for good, with a verdict kept.
spec ProbeVerdict observes eVerdict {
  start state Watching {
    on eVerdict do (why: tWhy) {
      assert false, "witness: a deterministic refusal kept a verdict";
    }
  }
}

// The owner made its ref from a finished child's commits.
spec ProbeRef observes eRef {
  start state Watching {
    on eRef do (p: (tip: int, arrived: int, desc: int)) {
      assert false, "witness: the owner made a ref for a child's commits";
    }
  }
}

// The executor had no room for the bundle, and the spawn was asked for again.
spec ProbeNoRoom observes eTransient {
  start state Watching {
    on eTransient do (why: tWhy) {
      assert why != W_NOROOM, "witness: the executor had no room and the spawn asked again";
    }
  }
}

// A session record that could not be read was asked about again.
spec ProbeUnreadable observes eTransient {
  start state Watching {
    on eTransient do (why: tWhy) {
      assert why != W_UNREADABLE, "witness: an unreadable record was asked about again";
    }
  }
}

// A join asked again after the child's session was ended was refused, and the
// owner made no ref. This is the cost the addendum accepts for a lost reply.
spec ProbeJoinLost observes eJoinLost {
  start state Watching {
    on eJoinLost do {
      assert false, "witness: a join found the child's session ended and no ref was made";
    }
  }
}
