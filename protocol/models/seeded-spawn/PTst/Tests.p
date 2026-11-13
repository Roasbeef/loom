// Test cases and the environment.
//
// The `tc*` cases without `Probe` in the name must pass. The system cases check
// every spec over a mix of faults; the `tcOnly*` cases check one spec each over the
// same traffic, so a spec that stops depending on a rule is reported under the name
// of the rule. The `tcProbe*` cases must fail: each finds a witness for a situation
// the specs are only meaningful if the model reaches.

module System = { Wire, Owner, Orch, Exec, Chaos, Harness };

// The environment: breaks either connection, restarts any machine, makes an asker
// give up, lets the child work, and delays the bundle, each as often as its budget
// allows and at times the scheduler chooses. Between actions it idles for a random
// number of its own steps, which spreads the faults over the whole run. When the
// budgets are spent it does what the drainer does eventually: it pokes the owner on
// a quiet network until the owner says it is done.
machine Chaos {
  var w1: machine;
  var w2: machine;
  var owner: machine;
  var orch: machine;
  var exec: machine;
  var plan: tPlan;
  var bundleSent: bool;
  var done: bool;
  var quiet: bool;

  start state Init {
    entry (p: (w1: machine, w2: machine, owner: machine, orch: machine, exec: machine, plan: tPlan)) {
      w1 = p.w1;
      w2 = p.w2;
      owner = p.owner;
      orch = p.orch;
      exec = p.exec;
      plan = p.plan;
      send this, eChaosStep;
      goto Acting;
    }
  }

  state Acting {
    on eChaosStep do {
      if (done) {
        return;
      }
      if (spent()) {
        if (!bundleSent) {
          bundleSent = true;
          send orch, eBundleArrives;
        }
        send owner, eQuiet;
        goto Finished;
      }
      if (choose(3) != 0) {
        send this, eChaosStep;
        return;
      }
      act();
      send this, eChaosStep;
    }

    on eOwnerDone do {
      done = true;
    }
  }

  state Finished {
    ignore eChaosStep, eOwnerDone;
  }

  fun spent(): bool {
    return plan.breaks1 + plan.breaks2 + plan.crashOrch + plan.crashExec + plan.crashOwner + plan.giveUps + plan.works == 0;
  }

  // Spends one unit of one budget.
  fun act() {
    var kinds: seq[int];
    var kind: int;
    if (choose(2) == 0) {
      send owner, ePoke;
    }
    if (plan.holdLate && !bundleSent && choose(2) == 0) {
      bundleSent = true;
      send orch, eBundleArrives;
    }
    if (plan.breaks1 > 0) {
      kinds += (sizeof(kinds), 0);
    }
    if (plan.breaks2 > 0) {
      kinds += (sizeof(kinds), 1);
    }
    if (plan.crashOrch > 0) {
      kinds += (sizeof(kinds), 2);
    }
    if (plan.crashExec > 0) {
      kinds += (sizeof(kinds), 3);
    }
    if (plan.crashOwner > 0) {
      kinds += (sizeof(kinds), 4);
    }
    if (plan.giveUps > 0) {
      kinds += (sizeof(kinds), 5);
    }
    if (plan.works > 0) {
      kinds += (sizeof(kinds), 6);
    }
    kind = choose(kinds);
    if (kind == 0) {
      plan.breaks1 = plan.breaks1 - 1;
      send w1, eBreak;
    } else if (kind == 1) {
      plan.breaks2 = plan.breaks2 - 1;
      send w2, eBreak;
    } else if (kind == 2) {
      plan.crashOrch = plan.crashOrch - 1;
      send w1, eBreak;
      send w2, eBreak;
      send orch, eCrashOrch;
    } else if (kind == 3) {
      plan.crashExec = plan.crashExec - 1;
      send w2, eBreak;
      send exec, eCrashExec;
    } else if (kind == 4) {
      plan.crashOwner = plan.crashOwner - 1;
      send w1, eBreak;
      send owner, eCrashOwner;
    } else if (kind == 5) {
      plan.giveUps = plan.giveUps - 1;
      send orch, eGiveUp;
    } else {
      plan.works = plan.works - 1;
      send exec, eChildWork;
      send orch, eChildWork;
    }
  }
}

// Builds the machines for one plan and starts the owner's drainer with a poke.
machine Harness {
  start state Init {
    entry (plan: tPlan) {
      var w1: machine;
      var w2: machine;
      var owner: machine;
      var orch: machine;
      var exec: machine;
      var chaos: machine;
      w1 = new Wire(1);
      w2 = new Wire(2);
      owner = new Owner(w1);
      exec = new Exec((w2 = w2, plan = plan));
      orch = new Orch((w1 = w1, w2 = w2, exec = exec, plan = plan));
      send w1, eWireEnds, (left = owner, right = orch);
      send w2, eWireEnds, (left = orch, right = exec);
      chaos = new Chaos((w1 = w1, w2 = w2, owner = owner, orch = orch, exec = exec, plan = plan));
      send owner, eKnowChaos, chaos;
      send owner, ePoke;
    }
  }
}
