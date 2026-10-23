// The properties of the evolution path (protocol-change/098, proposed). Each
// spec states its rule in a comment, in the same register as Specs.p. The code
// they cite does not exist yet; the citations name the proposal's pieces.

// A session has one executable slot: at most one generation serves at a time,
// and at most one prepared successor exists. `EvolutionStage` answers a serving
// generation of the same (candidate, generation) and otherwise supersedes the
// slot, so a re-send or a stage from a restarted runtime never starts a second
// serving generation and never joins a prepared one. `EvolutionPrepare` replaces
// an unpublished successor, so two are never prepared.
spec OneServingGeneration observes eSlot {
  start state Watching {
    on eSlot do (p: (serving: int, prepared: int)) {
      assert p.serving <= 1, format("{0} generations serve at once", p.serving);
      assert p.prepared <= 1, format("{0} prepared successors exist at once", p.prepared);
    }
  }
}

// No generation is live on the executor for an incarnation that is not the
// scope's current open incarnation. A generation starts only in an open scope
// at its own incarnation; an attach at a higher incarnation, a close and a VM
// restart each leave none behind (custody `Evolution` in `executor_plane`,
// protocol-change/098 "Where each part runs on the executor").
spec GenerationsFollowTheScope observes eInstStarted, eInstEnded, eScopeAttached, eScopeClosed, eVmCrashed {
  var live: map[int, int];
  var scopeInc: int;
  var open: bool;

  start state Watching {
    on eInstStarted do (p: (handle: int, gen: int, inc: int)) {
      assert open && p.inc == scopeInc, format("generation {0} started for incarnation {1} while the scope is at {2}", p.gen, p.inc, scopeInc);
      live[p.handle] = p.inc;
    }

    on eInstEnded do (h: int) {
      live -= (h);
    }

    on eScopeAttached do (p: (inc: int, token: int)) {
      var hs: seq[int];
      var h: int;
      scopeInc = p.inc;
      open = true;
      hs = keys(live);
      foreach (h in hs) {
        assert live[h] == p.inc, format("handle {0} of incarnation {1} outlived the attach of incarnation {2}", h, live[h], p.inc);
      }
    }

    on eScopeClosed do (inc: int) {
      open = false;
      assert sizeof(live) == 0, format("{0} generations outlived the close of incarnation {1}", sizeof(live), inc);
    }

    on eVmCrashed do {
      assert sizeof(live) == 0, format("{0} generations survived an executor crash", sizeof(live));
    }
  }
}

// A message carrying a stale incarnation or token never stages, publishes or
// aborts anything: whenever the plane acts, the message's incarnation and token
// are the scope's. This is the rule `Run` obeys through
// `exec_ledger.require_current`, applied to the evolution plane's own
// admission (protocol-change/098 "Node vocabulary").
spec StaleMessageActsNothing observes eActed {
  start state Watching {
    on eActed do (p: (op: tOp, handle: int, msgInc: int, msgToken: int, scopeInc: int, scopeToken: int)) {
      assert p.msgInc == p.scopeInc && p.msgToken == p.scopeToken, format("operation {0} on handle {1} acted for incarnation {2} token {3} while the scope held {4} and {5}", p.op, p.handle, p.msgInc, p.msgToken, p.scopeInc, p.scopeToken);
    }
  }
}

// A migration is applied on the executor at most once per (handle, target
// generation). `EvolutionPublish` is idempotent: a second publish of a
// published transition answers the same receipt and moves no state.
spec MigrationAppliedOnce observes eMigrated {
  var applied: set[(int, int)];

  start state Watching {
    on eMigrated do (p: (handle: int, target: int)) {
      assert !((p.handle, p.target) in applied), format("the migration of handle {0} to generation {1} was applied twice", p.handle, p.target);
      applied += ((p.handle, p.target));
    }
  }
}

// An abort is never applied after its publish. `EvolutionAbort` of a published
// transition is refused with `AlreadyPublished`, so a compensation that a dead
// runtime sent late cannot undo a migration the next runtime published.
spec NoAbortAfterPublish observes eTrPublished, eTrAborted {
  var published: set[(int, int)];

  start state Watching {
    on eTrPublished do (p: (handle: int, succ: int)) {
      published += ((p.handle, p.succ));
    }

    on eTrAborted do (p: (handle: int, succ: int)) {
      assert !((p.handle, p.succ) in published), format("the abort of successor {1} of handle {0} was applied after its publish", p.handle, p.succ);
    }
  }
}

// The executor never runs ahead of the catalogue. Whenever it serves a
// generation, the orchestrator's durable selection names that generation or a
// later one: the selection is committed before the publish is sent
// (protocol-change/098 "Authority stays on the orchestrator").
spec ExecutorNeverAheadOfCatalogue observes eSelected, eServedNow {
  var selected: int;

  start state Watching {
    on eSelected do (g: int) {
      selected = g;
    }

    on eServedNow do (g: int) {
      assert g <= selected, format("the executor serves generation {0} while the catalogue selects {1}", g, selected);
    }
  }
}

// Liveness: while the scope is open and has a plane, the executor's served
// generation converges to the catalogue's selection. A crashed executor has no
// plane until the next attach, and a closed scope serves nothing, so both rest
// the claim. P reports a hot monitor at the end of a run.
spec ServedConvergesToSelection observes eSelected, eServedNow, eScopeAttached, eScopeClosed, eVmCrashed {
  var selected: int;
  var served: int;
  var planeUp: bool;

  start cold state Settled {
    on eSelected do (g: int) {
      selected = g;
      check();
    }

    on eServedNow do (g: int) {
      served = g;
      check();
    }

    on eScopeAttached do (p: (inc: int, token: int)) {
      planeUp = true;
      check();
    }

    on eScopeClosed do (inc: int) {
      planeUp = false;
      served = 0;
      check();
    }

    on eVmCrashed do {
      planeUp = false;
      served = 0;
      check();
    }
  }

  hot state Behind {
    on eSelected do (g: int) {
      selected = g;
      check();
    }

    on eServedNow do (g: int) {
      served = g;
      check();
    }

    on eScopeAttached do (p: (inc: int, token: int)) {
      planeUp = true;
      check();
    }

    on eScopeClosed do (inc: int) {
      planeUp = false;
      served = 0;
      check();
    }

    on eVmCrashed do {
      planeUp = false;
      served = 0;
      check();
    }
  }

  fun check() {
    if (planeUp && served != selected) {
      goto Behind;
    }
    goto Settled;
  }
}

// An unconfirmed retirement keeps the live owner's cleanup obligation: an
// obligation is dropped only after the owner saw the executor confirm the
// retirement (`AllRetired`). `UnknownCleanup` keeps custody, the rule the live
// owner already follows for a scope close (protocol-change/098 "Node
// vocabulary", `EvolutionRetire`). The obligations are the owner's memory for
// one open: a dead owner's are found again through `Staged.superseded`, or
// settled by the scope close verdict.
spec CleanupCustodyKept observes eRetireSeen, eObligationDropped {
  var confirmed: set[int];

  start state Watching {
    on eRetireSeen do (h: int) {
      confirmed += (h);
    }

    on eObligationDropped do (h: int) {
      assert h in confirmed, format("the obligation for handle {0} was dropped before its retirement was confirmed", h);
    }
  }
}
