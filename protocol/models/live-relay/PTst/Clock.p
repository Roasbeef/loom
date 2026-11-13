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
// `aheadAt` is the tick at which a peer sends a poll whose `after` is ahead of
// anything the box queued, and `behindAt` one whose `after` is zero, which is
// behind what the box acknowledged once a poll has acknowledged a frame. The
// honest adapter sends neither, and a delayed copy of an old poll is the same
// poll as `behindAt` sends.
type tPlan = (ticks: int, settle: int, emits: seq[tEmit], cmds: seq[tCmdAt], breakAt: int, healAt: int, closeAt: int, stopAt: int, revokeAt: int, ownerAt: int, aheadAt: int, behindAt: int, laneDeadline: int, loses: int, dups: int, delays: int, short: int, hostile: int);

// `extra` are the machines of the further feeds of one spawner, which the Clock
// ticks too, and `cuts` their links, which a partition cuts with the first.
type tClockCfg = (plan: tPlan, gateway: machine, host: machine, link: machine, ui: machine, lane: machine, extra: seq[machine], cuts: seq[machine]);

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
  var cuts: seq[machine];

  start state Running {
    entry (c: tClockCfg) {
      var other: machine;
      plan = c.plan;
      gateway = c.gateway;
      link = c.link;
      ui = c.ui;
      lane = c.lane;
      cuts = c.cuts;
      all += (0, c.gateway);
      all += (1, c.host);
      all += (2, c.link);
      all += (3, c.ui);
      all += (4, c.lane);
      foreach (other in c.extra) {
        all += (sizeof(all), other);
      }
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
    var other: machine;
    if (plan.breakAt == t) {
      send link, eBreak;
      foreach (other in cuts) {
        send other, eBreak;
      }
    }
    if (plan.healAt == t) {
      send link, eHeal;
      foreach (other in cuts) {
        send other, eHeal;
      }
    }
    if (plan.behindAt == t) {
      send link, eToBox, (kind = RQ_POLL, pollId = 901, after = 0, wait = 0, n = 0, offset = 0, total = 0, cmd = CMD_FORWARD);
    }
    if (plan.aheadAt == t) {
      send link, eToBox, (kind = RQ_POLL, pollId = 900, after = 99, wait = 0, n = 0, offset = 0, total = 0, cmd = CMD_FORWARD);
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
      host = new FeedHost((link = link, gateway = gateway, directory = default(machine), attachAt = 0, hostile = plan.hostile));
      send gateway, eGwWire, host;
      ui = new UiFeed(link);
      lane = new Lane((ui = ui, deadline = plan.laneDeadline));
      send ui, eUiWire, lane;
      send link, eLinkWire, (host = host, ui = ui);
      if (plan.short == 1) {
        announce eShortPartition;
      }
      send ui, eOpen;
      new Clock((plan = plan, gateway = gateway, host = host, link = link, ui = ui, lane = lane, extra = default(seq[machine]), cuts = default(seq[machine])));
    }
  }
}

// Builds a spawner's feeds that share one directory with a cap, for the cap
// rule. Each feed has a gateway, a link, a page adapter and a lane of its own,
// and attaches at its own tick, and one Clock ticks them all. The first feed's
// machines are the Clock's own, and the others are its extra machines.
machine CapHarness {
  start state Init {
    entry (p: (plan: tPlan, attach: seq[int])) {
      var directory: machine;
      var gateway: machine;
      var host: machine;
      var link: machine;
      var ui: machine;
      var lane: machine;
      var gateway0: machine;
      var host0: machine;
      var link0: machine;
      var ui0: machine;
      var lane0: machine;
      var extra: seq[machine];
      var cuts: seq[machine];
      var i: int;
      directory = new Directory();
      while (i < sizeof(p.attach)) {
        gateway = new Gateway();
        link = new Link((loses = 0, dups = 0, delays = 0));
        host = new FeedHost((link = link, gateway = gateway, directory = directory, attachAt = p.attach[i], hostile = 0));
        send gateway, eGwWire, host;
        ui = new UiFeed(link);
        lane = new Lane((ui = ui, deadline = p.plan.laneDeadline));
        send ui, eUiWire, lane;
        send link, eLinkWire, (host = host, ui = ui);
        send ui, eOpen;
        if (i == 0) {
          gateway0 = gateway;
          host0 = host;
          link0 = link;
          ui0 = ui;
          lane0 = lane;
        } else {
          extra += (sizeof(extra), gateway);
          extra += (sizeof(extra), host);
          extra += (sizeof(extra), link);
          extra += (sizeof(extra), ui);
          extra += (sizeof(extra), lane);
          cuts += (sizeof(cuts), link);
        }
        i = i + 1;
      }
      new Clock((plan = p.plan, gateway = gateway0, host = host0, link = link0, ui = ui0, lane = lane0, extra = extra, cuts = cuts));
    }
  }
}
