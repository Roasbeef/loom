// The environment: breaks the connection, restarts the remote's VM, aborts the
// parent run's effect processes, ends a parent run, lets a child finish, and
// pokes the drainer, each as often as its budget allows and at times the
// scheduler chooses. Between actions it idles for a random number of its own
// steps, which spreads the faults over the whole run instead of spending them
// before the first message is sent.
//
// When the budgets are spent it does what the real clocks do eventually. The
// drainer makes two passes on a quiet network, and every deadline passes. A
// spawn answered after that finds the deadline already past, and the tick stops
// it.
machine Chaos {
  var wire: machine;
  var laptop: machine;
  var port: machine;
  var breaks: int;
  var crashes: int;
  var aborts: int;
  var ends: seq[int];
  var finishes: int;
  var pokes: int;

  start state Init {
    entry (p: (wire: machine, laptop: machine, port: machine, plan: tPlan)) {
      wire = p.wire;
      laptop = p.laptop;
      port = p.port;
      breaks = p.plan.breaks;
      crashes = p.plan.crashes;
      aborts = p.plan.aborts;
      ends = p.plan.ends;
      finishes = p.plan.finishes;
      pokes = p.plan.pokes;
      send this, eChaosStep;
      goto Acting;
    }
  }

  state Acting {
    on eChaosStep do {
      if (breaks + crashes + aborts + sizeof(ends) + finishes + pokes == 0) {
        finish();
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

  fun finish() {
    send laptop, eDrain;
    send laptop, eDrain;
    send port, eDeadlineAll;
  }

  fun act() {
    var a: int;
    var run: int;
    a = choose(6);
    if (a == 0 && breaks > 0) {
      breaks = breaks - 1;
      send wire, eBreak;
    } else if (a == 1 && crashes > 0) {
      crashes = crashes - 1;
      send wire, eCrashRemote;
    } else if (a == 2 && aborts > 0) {
      aborts = aborts - 1;
      send laptop, eAbort;
    } else if (a == 3 && sizeof(ends) > 0) {
      run = ends[0];
      ends -= (0);
      send wire, eSend, (sender = this, msg = (kind = K_RUN_ENDED, src = this, dest = port, site = 0, child = 0, st = CS_RUNNING, run = run, owner = run));
    } else if (a == 4 && finishes > 0) {
      finishes = finishes - 1;
      send port, eFinishOne;
    } else if (a == 5 && pokes > 0) {
      pokes = pokes - 1;
      send laptop, eDrain;
    }
  }
}

// What a test case does: the call sites the parent starts and the faults the
// environment may inflict.
type tPlan = (sites: seq[tPlanSite], breaks: int, crashes: int, aborts: int, ends: seq[int], finishes: int, pokes: int);

// Builds the system for one plan.
machine Harness {
  start state Init {
    entry (plan: tPlan) {
      var wire: machine;
      var port: machine;
      var laptop: machine;
      var s: tPlanSite;
      wire = new Wire();
      port = new Port(wire);
      send wire, eWirePort, port;
      laptop = new Laptop((wire = wire, port = port));
      foreach (s in plan.sites) {
        send laptop, eBegin, s;
      }
      new Chaos((wire = wire, laptop = laptop, port = port, plan = plan));
    }
  }
}
