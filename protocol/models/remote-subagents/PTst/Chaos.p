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
// it. The laptop's parent session opens again and the connection comes back, each
// ringing the remote's drainer: the fair reconnection the link keeper assumes,
// and a parent session that its owner opens.
//
// The mail faults are a child sending its parent a message (`upwards`), the
// remote's drainer taking a pass (`mailPasses`), the parent session closing
// (`closes`), the parent's run ending (`runEnds`) and the connection being
// brought back early (`reconnects`).
//
// The depth faults (phase 4) are a running child on the box starting a child of
// its own on a third orchestrator (`grands`) and the connection between the box
// and the third orchestrators breaking (`grandBreaks`). At the end the relay's
// drainer passes twice as well, and the third orchestrators' slots drain and
// their deadlines pass.
machine Chaos {
  var wire: machine;
  var laptop: machine;
  var port: machine;
  var below: tBelow;
  var breaks: int;
  var crashes: int;
  var aborts: int;
  var ends: seq[int];
  var finishes: int;
  var pokes: int;
  var deletes: int;
  var drains: int;
  var upwards: int;
  var mailPasses: int;
  var closes: int;
  var runEnds: int;
  var reconnects: int;
  var grands: int;
  var grandBreaks: int;

  start state Init {
    entry (p: (wire: machine, laptop: machine, port: machine, below: tBelow, plan: tPlan)) {
      wire = p.wire;
      laptop = p.laptop;
      port = p.port;
      below = p.below;
      breaks = p.plan.breaks;
      crashes = p.plan.crashes;
      aborts = p.plan.aborts;
      ends = p.plan.ends;
      finishes = p.plan.finishes;
      pokes = p.plan.pokes;
      deletes = p.plan.deletes;
      drains = p.plan.drains;
      upwards = p.plan.upwards;
      mailPasses = p.plan.mailPasses;
      closes = p.plan.closes;
      runEnds = p.plan.runEnds;
      reconnects = p.plan.reconnects;
      grands = p.plan.grands;
      grandBreaks = p.plan.grandBreaks;
      send this, eChaosStep;
      goto Acting;
    }
  }

  state Acting {
    on eChaosStep do {
      if (breaks + crashes + aborts + sizeof(ends) + finishes + pokes + deletes + drains + upwards + mailPasses + closes + runEnds + reconnects + grands + grandBreaks == 0) {
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
    var t: machine;
    send laptop, eDrain;
    send laptop, eDrain;
    send laptop, eParentOpen;
    send wire, eReconnect;
    send port, eSlotDrained;
    send port, eDeadlineAll;
    send below.relay, eDrain;
    send below.relay, eDrain;
    foreach (t in below.thirds) {
      send t, eSlotDrained;
      send t, eDeadlineAll;
    }
  }

  fun act() {
    var a: int;
    var run: int;
    a = choose(15);
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
      send wire, eSend, (sender = this, msg = (kind = K_RUN_ENDED, src = this, dest = port, site = 0, child = 0, st = CS_RUNNING, run = run, owner = run, id = 0, code = MAIL_DELIVERED));
    } else if (a == 4 && finishes > 0) {
      finishes = finishes - 1;
      send port, eFinishOne;
    } else if (a == 5 && pokes > 0) {
      pokes = pokes - 1;
      send laptop, eDrain;
    } else if (a == 6 && deletes > 0) {
      deletes = deletes - 1;
      send laptop, eDelete;
    } else if (a == 7 && drains > 0) {
      drains = drains - 1;
      send port, eSlotDrained;
    } else if (a == 8 && upwards > 0) {
      upwards = upwards - 1;
      send port, eUpward;
    } else if (a == 9 && mailPasses > 0) {
      mailPasses = mailPasses - 1;
      send port, eMailPass;
    } else if (a == 10 && closes > 0) {
      closes = closes - 1;
      send laptop, eParentClose;
    } else if (a == 11 && runEnds > 0) {
      runEnds = runEnds - 1;
      send laptop, eParentRunEnds;
    } else if (a == 12 && reconnects > 0) {
      reconnects = reconnects - 1;
      send wire, eReconnect;
    } else if (a == 13 && grands > 0) {
      grands = grands - 1;
      send port, eGrandSpawn;
    } else if (a == 14 && grandBreaks > 0) {
      grandBreaks = grandBreaks - 1;
      send below.wire, eBreak;
    }
  }
}

// What a test case does: the call sites the parent starts and the faults the
// environment may inflict. `deletes` is how often the parent session is deleted
// and `drains` how often the remote's slot for a released session drains before
// the run ends. The next five are the mail faults the module comment lists, and
// the last two the depth faults.
type tPlan = (sites: seq[tPlanSite], breaks: int, crashes: int, aborts: int, ends: seq[int], finishes: int, pokes: int, deletes: int, drains: int, upwards: int, mailPasses: int, closes: int, runEnds: int, reconnects: int, grands: int, grandBreaks: int);

// The machines below the box: the relay that plays the box's delegate session as
// a spawner, the wire between it and the third orchestrators, and the third
// orchestrators themselves, the allowed one first.
type tBelow = (relay: machine, wire: machine, thirds: seq[machine]);

// Builds the system for one plan. Every case has the depth-2 machines, and a
// case with no `grands` leaves them idle.
machine Harness {
  start state Init {
    entry (plan: tPlan) {
      var wire: machine;
      var port: machine;
      var laptop: machine;
      var below: machine;
      var allowed: machine;
      var other: machine;
      var relay: machine;
      var boxes: seq[machine];
      var thirds: seq[machine];
      var s: tPlanSite;
      wire = new Wire();
      port = new Port((wire = wire, base = 0, depth = 1));
      send wire, eWirePort, port;
      boxes += (0, port);
      laptop = new Laptop((wire = wire, ports = boxes));
      send port, eLaptop, laptop;

      below = new Wire();
      allowed = new Port((wire = below, base = 1000, depth = 2));
      other = new Port((wire = below, base = 2000, depth = 2));
      send below, eWirePort, allowed;
      thirds += (0, allowed);
      thirds += (1, other);
      relay = new Laptop((wire = below, ports = thirds));
      send port, eRelay, relay;

      foreach (s in plan.sites) {
        send laptop, eBegin, s;
      }
      new Chaos((wire = wire, laptop = laptop, port = port, below = (relay = relay, wire = below, thirds = thirds), plan = plan));
    }
  }
}
