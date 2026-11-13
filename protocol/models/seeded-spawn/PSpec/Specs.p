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

    on eSettled do {
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
