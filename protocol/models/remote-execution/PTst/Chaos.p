// The environment: breaks the connection, crashes the executor's VM, ends an
// open, or restarts a runtime, each as often as its budget allows and at times
// the scheduler chooses. Between actions it idles for a random number of its
// own steps, which spreads the faults over the whole run instead of spending
// them before the first request is sent.
machine Chaos {
  var wire: machine;
  var orch: machine;
  var breaks: int;
  var crashes: int;
  var opens: int;
  var restarts: int;

  start state Init {
    entry (p: (wire: machine, orch: machine, breaks: int, crashes: int, opens: int, restarts: int)) {
      wire = p.wire;
      orch = p.orch;
      breaks = p.breaks;
      crashes = p.crashes;
      opens = p.opens;
      restarts = p.restarts;
      send this, eChaosStep;
      goto Acting;
    }
  }

  state Acting {
    on eChaosStep do {
      if (breaks + crashes + opens + restarts == 0) {
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
    a = choose(4);
    if (a == 0 && breaks > 0) {
      breaks = breaks - 1;
      send wire, eBreak;
    } else if (a == 1 && crashes > 0) {
      crashes = crashes - 1;
      send wire, eCrashHost;
    } else if (a == 2 && opens > 0) {
      opens = opens - 1;
      send orch, eOpenCrash;
    } else if (a == 3 && restarts > 0) {
      restarts = restarts - 1;
      send orch, eRuntimeRestart;
    }
  }
}

// What a test case does: the calls the session makes, and the faults the
// environment may inflict.
type tPlan = (replays: seq[tReplay], acks: tAck, breaks: int, crashes: int, opens: int, restarts: int);

// Builds the system for one plan.
machine Harness {
  start state Init {
    entry (plan: tPlan) {
      var wire: machine;
      var host: machine;
      var orch: machine;
      wire = new Wire();
      host = new Host(wire);
      send wire, eWireHost, host;
      orch = new Orch((wire = wire, executor = host, replays = plan.replays, acks = plan.acks));
      new Chaos((wire = wire, orch = orch, breaks = plan.breaks, crashes = plan.crashes, opens = plan.opens, restarts = plan.restarts));
    }
  }
}
