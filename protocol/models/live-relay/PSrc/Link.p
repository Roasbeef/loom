// The link between the laptop and the box, for poll answers and send answers
// alike. A message in either direction may be lost, duplicated or delayed, each
// within a budget the test case sets. A partition drops every message in both
// directions until it heals. A delayed message is held until the next tick and
// then delivered, so it can arrive after a later message and after the sender
// gave up on it. Nothing the link does is visible to its endpoints except
// through the messages that arrive.
machine Link {
  var host: machine;
  var ui: machine;
  var cut: int;
  var loses: int;
  var dups: int;
  var delays: int;
  var heldReq: seq[tReq];
  var heldAns: seq[tAns];

  start state Running {
    entry (p: (loses: int, dups: int, delays: int)) {
      loses = p.loses;
      dups = p.dups;
      delays = p.delays;
    }

    on eLinkWire do (w: (host: machine, ui: machine)) {
      host = w.host;
      ui = w.ui;
    }

    on eToBox do (m: tReq) {
      if (cut == 1) {
        announce eLinkDropped;
        return;
      }
      if (loses > 0 && choose(3) == 0) {
        loses = loses - 1;
        return;
      }
      if (delays > 0 && choose(3) == 0) {
        delays = delays - 1;
        heldReq += (sizeof(heldReq), m);
        return;
      }
      send host, eReq, m;
      if (dups > 0 && choose(3) == 0) {
        dups = dups - 1;
        send host, eReq, m;
      }
    }

    on eToLaptop do (m: tAns) {
      if (cut == 1) {
        announce eLinkDropped;
        return;
      }
      if (loses > 0 && choose(3) == 0) {
        loses = loses - 1;
        return;
      }
      if (delays > 0 && choose(3) == 0) {
        delays = delays - 1;
        heldAns += (sizeof(heldAns), m);
        return;
      }
      send ui, eAns, m;
      if (dups > 0 && choose(3) == 0) {
        dups = dups - 1;
        send ui, eAns, m;
      }
    }

    on eBreak do {
      cut = 1;
      announce eCut;
    }

    on eHeal do {
      cut = 0;
      announce eHealed;
    }

    // A tick releases the delayed messages. A message still held when a
    // partition begins is lost with the rest.
    on eTick do (c: machine) {
      var q: tReq;
      var a: tAns;
      foreach (q in heldReq) {
        if (cut == 0) {
          send host, eReq, q;
        }
      }
      foreach (a in heldAns) {
        if (cut == 0) {
          send ui, eAns, a;
        }
      }
      heldReq = default(seq[tReq]);
      heldAns = default(seq[tAns]);
      send c, eAck;
    }

    on eFlush do (c: machine) {
      send c, eAck;
    }
  }
}
