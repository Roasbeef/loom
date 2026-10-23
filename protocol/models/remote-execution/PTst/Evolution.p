// The environment, the harness and the test cases of the evolution path
// (protocol-change/098, proposed). The machines are in PSrc/Evolution.p and the
// properties in PSpec/EvolutionSpecs.p. The wire is the execution model's.

// The environment: connection drops and executor VM crashes on the wire, and
// the three ways the orchestrator's side of a session ends something. An open
// crash mints a new attach token at the same incarnation. A runtime restart
// starts a new live owner under the same token. A reopen closes the scope and
// attaches at the next incarnation. Each happens as often as its budget allows
// and at times the scheduler chooses.
machine EvolutionChaos {
  var wire: machine;
  var cat: machine;
  var breaks: int;
  var crashes: int;
  var opens: int;
  var restarts: int;
  var reopens: int;

  start state Init {
    entry (p: (wire: machine, cat: machine, breaks: int, crashes: int, opens: int, restarts: int, reopens: int)) {
      wire = p.wire;
      cat = p.cat;
      breaks = p.breaks;
      crashes = p.crashes;
      opens = p.opens;
      restarts = p.restarts;
      reopens = p.reopens;
      send this, eChaosStep;
      goto Acting;
    }
  }

  state Acting {
    on eChaosStep do {
      if (breaks + crashes + opens + restarts + reopens == 0) {
        goto Finished;
      }
      if (choose(3) != 0) {
        send this, eChaosStep;
        return;
      }
      act();
      send this, eChaosStep;
    }
  }

  state Finished {
    ignore eChaosStep;
  }

  fun act() {
    var a: int;
    a = choose(5);
    if (a == 0 && breaks > 0) {
      breaks = breaks - 1;
      send wire, eBreak;
    } else if (a == 1 && crashes > 0) {
      crashes = crashes - 1;
      send wire, eCrashHost;
    } else if (a == 2 && opens > 0) {
      opens = opens - 1;
      send cat, eOpenCrash;
    } else if (a == 3 && restarts > 0) {
      restarts = restarts - 1;
      send cat, eRuntimeRestart;
    } else if (a == 4 && reopens > 0) {
      reopens = reopens - 1;
      send cat, eReopen;
    }
  }
}

// What an evolution case does. `attempts` is how many migrations the catalogue
// lets the owners start. `casFailures` and `casLost` bound the compare-and-sets
// that are rejected and that commit with the reply lost. `cleanupFaults` bounds
// the retirements the executor cannot confirm. `deaths` bounds the owners that
// die right after they hand a request to the wire, each a runtime restart or an
// open ending, so a dead owner's request is in flight beside its successor's.
type tEPlan = (attempts: int, casFailures: int, casLost: int, cleanupFaults: int, breaks: int, crashes: int, opens: int, restarts: int, reopens: int, deaths: int, deathAt: tKind, deathsAt: int);

machine EvolutionHarness {
  start state Init {
    entry (plan: tEPlan) {
      var wire: machine;
      var plane: machine;
      var cat: machine;
      wire = new Wire();
      plane = new EvolutionPlane((wire = wire, cleanupFaults = plan.cleanupFaults));
      send wire, eWireHost, plane;
      cat = new Catalogue((wire = wire, executor = plane, attempts = plan.attempts, casFailures = plan.casFailures, casLost = plan.casLost, deaths = plan.deaths, deathAt = plan.deathAt, deathsAt = plan.deathsAt));
      new EvolutionChaos((wire = wire, cat = cat, breaks = plan.breaks, crashes = plan.crashes, opens = plan.opens, restarts = plan.restarts, reopens = plan.reopens));
    }
  }
}

module EvolutionSystem = { Wire, EvolutionPlane, Catalogue, LiveOwner, EvolutionChaos, EvolutionHarness };

// One migration, no faults: stage, prepare, commit, publish, retire.
machine TestEvolutionQuiet {
  start state Init {
    entry {
      new EvolutionHarness((attempts = 1, casFailures = 0, casLost = 0, cleanupFaults = 0, breaks = 0, crashes = 0, opens = 0, restarts = 0, reopens = 0, deaths = 0, deathAt = K_E_CLOSE, deathsAt = 0));
    }
  }
}

// Dropped connections lose requests and replies, a compare-and-set loses its
// reply, and a retirement is not confirmed once.
machine TestEvolutionPartition {
  start state Init {
    entry {
      new EvolutionHarness((attempts = 1, casFailures = 0, casLost = 1, cleanupFaults = 1, breaks = 3, crashes = 0, opens = 0, restarts = 0, reopens = 0, deaths = 0, deathAt = K_E_CLOSE, deathsAt = 0));
    }
  }
}

// Runtime restarts inside one open, with a rejected compare-and-set and a
// second attempt: a dead runtime's abort can arrive after the next runtime's
// publish, under the same token.
machine TestEvolutionRestart {
  start state Init {
    entry {
      new EvolutionHarness((attempts = 2, casFailures = 1, casLost = 0, cleanupFaults = 0, breaks = 1, crashes = 0, opens = 0, restarts = 1, reopens = 0, deaths = 3, deathAt = K_E_CLOSE, deathsAt = 0));
    }
  }
}

// A rejected compare-and-set, an abort, and a runtime that dies right after it
// sends the abort. The next runtime prepares the same transition again, and the
// dead runtime's abort can arrive after the next runtime's publish, under the
// same token.
machine TestEvolutionAbortRace {
  start state Init {
    entry {
      new EvolutionHarness((attempts = 2, casFailures = 1, casLost = 0, cleanupFaults = 0, breaks = 0, crashes = 0, opens = 0, restarts = 0, reopens = 0, deaths = 0, deathAt = K_E_ABORT, deathsAt = 1));
    }
  }
}

// Orchestrator opens ending: a new token at the same incarnation, with the
// dead open's requests still in flight and a lost compare-and-set reply.
machine TestEvolutionOpen {
  start state Init {
    entry {
      new EvolutionHarness((attempts = 2, casFailures = 0, casLost = 1, cleanupFaults = 1, breaks = 1, crashes = 0, opens = 1, restarts = 0, reopens = 0, deaths = 2, deathAt = K_E_CLOSE, deathsAt = 0));
    }
  }
}

// A scope close and a reopen at the next incarnation, beside an open ending.
machine TestEvolutionReopen {
  start state Init {
    entry {
      new EvolutionHarness((attempts = 2, casFailures = 0, casLost = 0, cleanupFaults = 1, breaks = 1, crashes = 0, opens = 1, restarts = 0, reopens = 2, deaths = 0, deathAt = K_E_CLOSE, deathsAt = 0));
    }
  }
}

// An executor crash under a migration, with an open and a reopen after it.
machine TestEvolutionCrash {
  start state Init {
    entry {
      new EvolutionHarness((attempts = 2, casFailures = 0, casLost = 1, cleanupFaults = 0, breaks = 1, crashes = 1, opens = 1, restarts = 0, reopens = 1, deaths = 0, deathAt = K_E_CLOSE, deathsAt = 0));
    }
  }
}

// Every fault.
machine TestEvolutionAll {
  start state Init {
    entry {
      new EvolutionHarness((attempts = 2, casFailures = 1, casLost = 1, cleanupFaults = 1, breaks = 2, crashes = 1, opens = 1, restarts = 1, reopens = 1, deaths = 2, deathAt = K_E_CLOSE, deathsAt = 0));
    }
  }
}

test tcEvolutionQuiet [main = TestEvolutionQuiet]:
  assert OneServingGeneration, GenerationsFollowTheScope, StaleMessageActsNothing, MigrationAppliedOnce, NoAbortAfterPublish, ExecutorNeverAheadOfCatalogue, ServedConvergesToSelection, CleanupCustodyKept in
  (union EvolutionSystem, { TestEvolutionQuiet });

test tcEvolutionPartition [main = TestEvolutionPartition]:
  assert OneServingGeneration, GenerationsFollowTheScope, StaleMessageActsNothing, MigrationAppliedOnce, NoAbortAfterPublish, ExecutorNeverAheadOfCatalogue, ServedConvergesToSelection, CleanupCustodyKept in
  (union EvolutionSystem, { TestEvolutionPartition });

test tcEvolutionRestart [main = TestEvolutionRestart]:
  assert OneServingGeneration, GenerationsFollowTheScope, StaleMessageActsNothing, MigrationAppliedOnce, NoAbortAfterPublish, ExecutorNeverAheadOfCatalogue, ServedConvergesToSelection, CleanupCustodyKept in
  (union EvolutionSystem, { TestEvolutionRestart });

test tcEvolutionOpen [main = TestEvolutionOpen]:
  assert OneServingGeneration, GenerationsFollowTheScope, StaleMessageActsNothing, MigrationAppliedOnce, NoAbortAfterPublish, ExecutorNeverAheadOfCatalogue, ServedConvergesToSelection, CleanupCustodyKept in
  (union EvolutionSystem, { TestEvolutionOpen });

test tcEvolutionReopen [main = TestEvolutionReopen]:
  assert OneServingGeneration, GenerationsFollowTheScope, StaleMessageActsNothing, MigrationAppliedOnce, NoAbortAfterPublish, ExecutorNeverAheadOfCatalogue, ServedConvergesToSelection, CleanupCustodyKept in
  (union EvolutionSystem, { TestEvolutionReopen });

test tcEvolutionCrash [main = TestEvolutionCrash]:
  assert OneServingGeneration, GenerationsFollowTheScope, StaleMessageActsNothing, MigrationAppliedOnce, NoAbortAfterPublish, ExecutorNeverAheadOfCatalogue, ServedConvergesToSelection, CleanupCustodyKept in
  (union EvolutionSystem, { TestEvolutionCrash });

test tcEvolutionAbortRace [main = TestEvolutionAbortRace]:
  assert OneServingGeneration, GenerationsFollowTheScope, StaleMessageActsNothing, MigrationAppliedOnce, NoAbortAfterPublish, ExecutorNeverAheadOfCatalogue, ServedConvergesToSelection, CleanupCustodyKept in
  (union EvolutionSystem, { TestEvolutionAbortRace });

test tcEvolutionAll [main = TestEvolutionAll]:
  assert OneServingGeneration, GenerationsFollowTheScope, StaleMessageActsNothing, MigrationAppliedOnce, NoAbortAfterPublish, ExecutorNeverAheadOfCatalogue, ServedConvergesToSelection, CleanupCustodyKept in
  (union EvolutionSystem, { TestEvolutionAll });

// One spec each, for mutate.py, over the traffic that reaches the rule.
test tcOnlyOneServingGeneration [main = TestEvolutionRestart]:
  assert OneServingGeneration in (union EvolutionSystem, { TestEvolutionRestart });

test tcOnlyMigrationOnce [main = TestEvolutionPartition]:
  assert MigrationAppliedOnce in (union EvolutionSystem, { TestEvolutionPartition });

test tcOnlyNoAbortAfterPublish [main = TestEvolutionAbortRace]:
  assert NoAbortAfterPublish in (union EvolutionSystem, { TestEvolutionAbortRace });

test tcOnlyGenerationsFollowTheScope [main = TestEvolutionReopen]:
  assert GenerationsFollowTheScope in (union EvolutionSystem, { TestEvolutionReopen });

test tcOnlyStaleMessageActsNothing [main = TestEvolutionOpen]:
  assert StaleMessageActsNothing in (union EvolutionSystem, { TestEvolutionOpen });

test tcOnlyCleanupCustody [main = TestEvolutionPartition]:
  assert CleanupCustodyKept in (union EvolutionSystem, { TestEvolutionPartition });

test tcOnlyExecutorNeverAhead [main = TestEvolutionRestart]:
  assert ExecutorNeverAheadOfCatalogue in (union EvolutionSystem, { TestEvolutionRestart });

test tcOnlyServedConverges [main = TestEvolutionOpen]:
  assert ServedConvergesToSelection in (union EvolutionSystem, { TestEvolutionOpen });

// Probes, one per situation the model must reach.
test tcProbeMigrationApplied [main = TestEvolutionQuiet]:
  assert ProbeMigrationApplied in (union EvolutionSystem, { TestEvolutionQuiet });

test tcProbeStageResentJoins [main = TestEvolutionPartition]:
  assert ProbeStageResentJoins in (union EvolutionSystem, { TestEvolutionPartition });

test tcProbeStageAfterRestartJoins [main = TestEvolutionRestart]:
  assert ProbeStageAfterRestartJoins in (union EvolutionSystem, { TestEvolutionRestart });

test tcProbePublishResentJoins [main = TestEvolutionPartition]:
  assert ProbePublishResentJoins in (union EvolutionSystem, { TestEvolutionPartition });

test tcProbeAbortStale [main = TestEvolutionAbortRace]:
  assert ProbeAbortStale in (union EvolutionSystem, { TestEvolutionAbortRace });

test tcProbeStalePublishRefused [main = TestEvolutionOpen]:
  assert ProbeStalePublishRefused in (union EvolutionSystem, { TestEvolutionOpen });

test tcProbeStaleStageRefused [main = TestEvolutionOpen]:
  assert ProbeStaleStageRefused in (union EvolutionSystem, { TestEvolutionOpen });

test tcProbeRecoveryStagesCommitted [main = TestEvolutionOpen]:
  assert ProbeRecoveryStagesCommitted in (union EvolutionSystem, { TestEvolutionOpen });

test tcProbeStaleGenerationRefused [main = TestEvolutionRestart]:
  assert ProbeStaleGenerationRefused in (union EvolutionSystem, { TestEvolutionRestart });

test tcProbeStageSupersedes [main = TestEvolutionOpen]:
  assert ProbeStageSupersedes in (union EvolutionSystem, { TestEvolutionOpen });

test tcProbeStaleRetireRefused [main = TestEvolutionOpen]:
  assert ProbeStaleRetireRefused in (union EvolutionSystem, { TestEvolutionOpen });

test tcProbeCasReconciled [main = TestEvolutionPartition]:
  assert ProbeCasReconciled in (union EvolutionSystem, { TestEvolutionPartition });

test tcProbeCleanupUnconfirmed [main = TestEvolutionPartition]:
  assert ProbeCleanupUnconfirmed in (union EvolutionSystem, { TestEvolutionPartition });

test tcProbeGenerationLostInCrash [main = TestEvolutionCrash]:
  assert ProbeGenerationLostInCrash in (union EvolutionSystem, { TestEvolutionCrash });

test tcProbePrepareReplaced [main = TestEvolutionAbortRace]:
  assert ProbePrepareReplaced in (union EvolutionSystem, { TestEvolutionAbortRace });
