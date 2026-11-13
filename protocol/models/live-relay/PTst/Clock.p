// The environment: a logical clock and a script of faults.
//
// A plan names, for each tick, which events the environment injects (a push from
// the gateway, a command from the lane, a partition beginning or healing, the
// page closing, the session stopping, the owner approving at the box). The
// Clock performs a tick's injections, then lets the system settle, then sends one
// tick to every machine and waits for all acknowledgements, then settles again.
//
// Settling is `settle` rounds. In each round the Clock sends a flush to every
// machine and waits for every acknowledgement. A machine acknowledges a flush
// only after it handled every event queued before it, and anything it sent
// meanwhile is queued before its acknowledgement. So after `settle` rounds every
// chain of at most `settle` messages has run to the end, and a tick never
// overtakes a message that is still in flight. This is the synchrony the
// liveness property needs: a lease or a deadline passes only because time passed
// and not because the scheduler delayed a message. With `settle` of zero the
// ticks can overtake messages, which the cases that want adversarial timing use.
//
// Nothing here is a spec. The Harness builds the system for one plan.

type tEmit = (at: int, size: int);
type tCmdAt = (at: int, cmd: tCmd, pieces: int);

// A tick index of -1 means never.
type tPlan = (ticks: int, settle: int, emits: seq[tEmit], cmds: seq[tCmdAt], breakAt: int, healAt: int, closeAt: int, stopAt: int, revokeAt: int, ownerAt: int, laneDeadline: int, loses: int, dups: int, delays: int, short: int, hostile: int);

type tClockCfg = (plan: tPlan, gateway: machine, host: machine, link: machine, ui: machine, lane: machine);

machine Clock {
  var plan: tPlan;
  var gateway: machine;
  var link: machine;
  var ui: machine;
  var all: seq[machine];
  var t: int;
  var stage: int;
  var flushLeft: int;
  var pending: int;
  var lane: machine;

  start state Running {
    entry (c: tClockCfg) {
      plan = c.plan;
      gateway = c.gateway;
      link = c.link;
      ui = c.ui;
      lane = c.lane;
      all += (0, c.gateway);
      all += (1, c.host);
      all += (2, c.link);
      all += (3, c.ui);
      all += (4, c.lane);
      act();
      flushLeft = plan.settle;
      step();
    }

    on eAck do {
      pending = pending - 1;
      if (pending == 0) {
        step();
      }
    }
  }

  // The next move of the schedule: a flush round, the tick, a second settle, or
  // the injections of the next tick.
  fun step() {
    if (flushLeft > 0) {
      flushLeft = flushLeft - 1;
      ask(0);
      return;
    }
    if (stage == 0) {
      stage = 1;
      ask(1);
      return;
    }
    if (stage == 1) {
      stage = 2;
      flushLeft = plan.settle;
      step();
      return;
    }
    t = t + 1;
    if (t >= plan.ticks) {
      return;
    }
    stage = 0;
    act();
    flushLeft = plan.settle;
    step();
  }

  fun ask(kind: int) {
    var m: machine;
    pending = sizeof(all);
    foreach (m in all) {
      if (kind == 0) {
        send m, eFlush, this;
      } else {
        send m, eTick, this;
      }
    }
  }

  fun act() {
    var e: tEmit;
    var c: tCmdAt;
    if (plan.breakAt == t) {
      send link, eBreak;
    }
    if (plan.healAt == t) {
      send link, eHeal;
    }
    foreach (e in plan.emits) {
      if (e.at == t) {
        send gateway, eEmit, e.size;
      }
    }
    foreach (c in plan.cmds) {
      if (c.at == t) {
        send lane, eLaneCmd, (cmd = c.cmd, pieces = c.pieces);
      }
    }
    if (plan.closeAt == t) {
      send ui, eClose;
    }
    if (plan.stopAt == t) {
      send gateway, eStopSession;
    }
    if (plan.revokeAt == t) {
      send gateway, eRevoke;
    }
    if (plan.ownerAt == t) {
      send gateway, eLocalApprove, this;
    }
  }
}

// Builds the system for one plan. The wiring is sent as events because the
// machines refer to each other in a cycle.
machine Harness {
  start state Init {
    entry (plan: tPlan) {
      var gateway: machine;
      var host: machine;
      var link: machine;
      var ui: machine;
      var lane: machine;
      gateway = new Gateway();
      link = new Link((loses = plan.loses, dups = plan.dups, delays = plan.delays));
      host = new FeedHost((link = link, gateway = gateway, hostile = plan.hostile));
      send gateway, eGwWire, host;
      ui = new UiFeed(link);
      lane = new Lane((ui = ui, deadline = plan.laneDeadline));
      send ui, eUiWire, lane;
      send link, eLinkWire, (host = host, ui = ui);
      if (plan.short == 1) {
        announce eShortPartition;
      }
      send ui, eOpen;
      new Clock((plan = plan, gateway = gateway, host = host, link = link, ui = ui, lane = lane));
    }
  }
}
