// The lane: the session channel on the laptop, which is stop-and-wait. It
// transmits one frame, then waits for the reply that answers it. Other frames
// that arrive meanwhile (pushes) are delivered and change nothing. A reply that
// has not come when the deadline passes is an unknown outcome, and the lane
// fails, as in the proposal. A lane whose feed ended fails too.
machine Lane {
  var ui: machine;
  var deadline: int;
  var nextN: int;
  var pending: seq[tLaneCmd];
  var waiting: int;
  var age: int;
  var failed: int;

  start state Running {
    entry (p: (ui: machine, deadline: int)) {
      ui = p.ui;
      deadline = p.deadline;
      nextN = 1;
    }

    on eLaneCmd do (c: tLaneCmd) {
      pending += (sizeof(pending), c);
      pump();
    }

    on eDeliver do (f: tFrame) {
      if (failed == 0 && waiting != 0 && f.fk == FK_REPLY && f.req == waiting) {
        waiting = 0;
        pump();
      }
    }

    on eUiEnded do (k: tEnded) {
      fail();
    }

    on eTick do (c: machine) {
      if (failed == 0 && waiting != 0) {
        age = age + 1;
        if (age >= deadline) {
          fail();
        }
      }
      send c, eAck;
    }

    on eFlush do (c: machine) {
      send c, eAck;
    }
  }

  fun pump() {
    var c: tLaneCmd;
    var n: int;
    if (failed == 0 && waiting == 0 && sizeof(pending) > 0) {
      c = pending[0];
      pending -= (0);
      n = nextN;
      nextN = nextN + 1;
      waiting = n;
      age = 0;
      announce eLaneTx, n;
      send ui, eLaneSubmit, (n = n, cmd = c.cmd, total = c.pieces);
    }
  }

  fun fail() {
    if (failed == 0) {
      failed = 1;
      announce eLaneFailed;
    }
  }
}
