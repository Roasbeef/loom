// The properties the model checks. Each spec is named after the rule it encodes,
// and the comment above it cites where that rule lives. The rules come from
// protocol-change/107 (slices 4a to 4c) and from `client/spawn_seed`,
// `client/seed_landing` and `client/delegate_host`.

// The child's first turn never runs before the seed is applied. The Agency's
// spawn is the child's first turn, and `spawn_seed.land` returns to its caller
// only after the executor confirmed the apply (or the directory copy was made), so
// a child never starts on a half-made or empty workspace. A restart between the
// confirmation and the spawn, a lost reply and a retried land leave the order
// alone.
spec FirstTurnAfterSeed observes eTreeSeeded, eFirstTurn {
  var seeded: bool;

  start state Watching {
    on eTreeSeeded do {
      seeded = true;
    }

    on eFirstTurn do {
      assert seeded, "the child's first turn ran before the seed was applied";
    }
  }
}

// At most one delegate session exists for the child. The registry creates a
// session under a request key derived from the spawner, the parent and the child,
// so a creation retried after a restart lands on the registration it reserved
// (`delegate_host.creation_for`, `delegate_key`). The count starts again when the
// session is released.
spec AtMostOneSession observes eSessionMade, eSessionReleased {
  var live: int;

  start state Watching {
    on eSessionMade do {
      live = live + 1;
      assert live <= 1, "a second delegate session exists for the same child";
    }

    on eSessionReleased do {
      live = live - 1;
    }
  }
}

// A state is applied at most once per scope: the tree is seeded once, however many
// apply requests are sent, because an apply of the tip the tree already has is
// answered and touches nothing.
spec AppliedAtMostOnce observes eSeedEffective {
  var applied: int;

  start state Watching {
    on eSeedEffective do {
      applied = applied + 1;
      assert applied <= 1, "the seed was applied to the same scope twice";
    }
  }
}

// A retry never applies an older tip over a newer one. The executor takes an apply
// over a tree the child has worked in, because it cannot tell one from a fresh
// tree, so the rule rests on the orchestrator's check that the session has not
// begun, made at the moment before the request.
spec NoOlderOverNewer observes eApplied {
  start state Watching {
    on eApplied do (p: (before: int, after: int)) {
      assert !(p.before > p.after), "an older tip was applied over a newer one";
    }
  }
}

// The owner's ref names only the commits the child's capture described. A bundle
// that arrived shorter than its description, or one that does not match it, is
// not made into a ref (`spawn_return`, `return_apply`).
spec RefNamesOnlyDescribedCommits observes eRef {
  start state Watching {
    on eRef do (p: (tip: int, arrived: int, desc: int)) {
      assert p.arrived == p.desc, "the owner's ref names a bundle that is not the one described";
    }
  }
}

// A verdict is kept only for a refusal the same inputs get again. A failure that
// asking again can cure (no room, a fence that moved, no answer, a record that
// could not be read) must leave the spawn retryable (`seed_landing.keeps_verdict`).
spec NoPermanentVerdictFromTransient observes eVerdict {
  start state Watching {
    on eVerdict do (why: tWhy) {
      assert why == W_BADSTATE || why == W_WORKSPACE, "a transient failure was kept as a permanent verdict";
    }
  }
}

// "Cannot tell" is never read as "has begun". The answer to whether the child's
// session has begun is skipped over only when the child has begun
// (`seed_landing.gate`, `session_states.Freshness`).
spec UnreadableIsNotBegun observes eGate {
  start state Watching {
    on eGate do (actuallyBegun: bool) {
      assert actuallyBegun, "a session that had not begun was taken for one that had";
    }
  }
}

// A seeded spawn that is asked for ends: the child was started with the seed
// applied, or the spawn was refused for a deterministic reason. Bounded faults
// delay the end and cannot lose it. P reports a violation when a run ends with the
// monitor in the hot state.
spec EverySpawnEnds observes eSpawnAsked, eOutcomeSpawned, eOutcomeRefused {
  start cold state Quiet {
    on eSpawnAsked goto Waiting;
  }

  hot state Waiting {
    on eOutcomeSpawned goto Over;
    on eOutcomeRefused goto Over;
  }

  cold state Over {
    ignore eSpawnAsked, eOutcomeSpawned, eOutcomeRefused;
  }
}

// Every settled child's session is released. A child is settled when a verdict is
// kept for it or its result is stored, and its session is ended from then on, by
// the step that follows or by the next ask.
spec EverySettledChildIsReleased observes eSessionMade, eSessionReleased, eSettled, eVerdict {
  var live: bool;

  start cold state Quiet {
    on eSessionMade do {
      live = true;
    }

    on eSessionReleased do {
      live = false;
    }

    on eSettled do (tip: int) {
      if (live) {
        goto Owing;
      }
    }

    on eVerdict do (why: tWhy) {
      if (live) {
        goto Owing;
      }
    }
  }

  hot state Owing {
    on eSessionReleased do {
      live = false;
      goto Quiet;
    }

    ignore eSessionMade, eSettled, eVerdict;
  }
}

// A join asked again after its child settled and its session was released gets the
// answer the first one did. The sender asks again by design: a wait made from a
// program is deferred and retried, a second wait names handles that settled in the
// first, and a reply can be lost. The settled answer is kept before the session is
// ended (`spawn_return.keep`), and `child_join` answers from it.
spec JoinIsRepeatable observes eGone {
  start state Watching {
    on eGone do (settled: bool) {
      assert !settled, "a join asked again after the child settled was refused";
    }
  }
}

// The commits a child made reach the parent's repository as one ref, not twice.
spec OneRefPerChild observes eRef {
  var refs: int;

  start state Watching {
    on eRef do (p: (tip: int, arrived: int, desc: int)) {
      refs = refs + 1;
      assert refs <= 1, "the child's commits were made into a ref twice";
    }
  }
}

// The commits are not lost: a child that settled with work to return has them in the
// parent's repository once the faults are over, across a lost reply, a resend, an
// executor that restarted and a store with no room.
spec EveryFinishedWorkIsReturned observes eSettled, eRef {
  start cold state Quiet {
    on eSettled do (tip: int) {
      if (tip > 1) {
        goto Owing;
      }
    }

    ignore eRef;
  }

  hot state Owing {
    on eRef do (p: (tip: int, arrived: int, desc: int)) {
      goto Returned;
    }

    ignore eSettled;
  }

  cold state Returned {
    ignore eSettled, eRef;
  }
}

// A session is not released while its child runs. The child runs from its first turn
// until its run ends, by finishing, by a run end or by a restart.
spec NoReleaseWhileRunning observes eFirstTurn, eChildEnded, eSessionReleased {
  var running: bool;

  start state Watching {
    on eFirstTurn do {
      running = true;
    }

    on eChildEnded do {
      running = false;
    }

    on eSessionReleased do {
      assert !running, "a session was released while its child was running";
    }
  }
}

// A session is not released before the settled answer is kept, because the parent may
// not have heard it yet and the session is where the report lives.
spec ResultKeptBeforeRelease observes eSettleBegan, eKept, eSessionReleased {
  var settling: bool;
  var kept: bool;

  start state Watching {
    on eSettleBegan do {
      settling = true;
    }

    on eKept do {
      kept = true;
    }

    on eSessionReleased do {
      assert !settling || kept, "a session was released before its settled answer was kept";
    }
  }
}

// An executor runs one checkout at a time for a scope and state. A request that
// arrives while one is running joins it.
spec OneApplyAtATime observes eApplyStarted, eApplyEnded {
  var running: int;

  start state Watching {
    on eApplyStarted do {
      running = running + 1;
      assert running <= 1, "two checkouts ran at once for one scope";
    }

    on eApplyEnded do {
      running = running - 1;
    }
  }
}

// The end of a run stops the children that run in sessions of their own, whatever
// becomes of the pair's session. A spawner whose seeded children fill its cap cannot
// make the pair's session, and that must not leave the children running.
spec RunEndStopsTheChildren observes eRunEndHandled {
  start state Watching {
    on eRunEndHandled do (childStillRuns: bool) {
      assert !childStillRuns, "a run end left a child running because the pair's session failed";
    }
  }
}
