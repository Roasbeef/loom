// The network between two machines. A copy of the state transfer model's, with
// one generic message and a name for each link.
//
// Erlang orders messages per sender and receiver pair, so each direction keeps one
// queue, and each step delivers the head of either non-empty queue. A broken
// connection loses every message in flight in both directions and tells both ends
// once, which is the `PortGone` an exchange ends with. A message sent after the
// break travels normally, because Erlang reconnects on the next send.
machine Wire {
  var id: int;
  var left: machine;
  var right: machine;
  var toRight: seq[tMsg];
  var toLeft: seq[tMsg];
  var stepPending: bool;

  start state Running {
    entry (n: int) {
      id = n;
    }

    on eWireEnds do (p: (left: machine, right: machine)) {
      left = p.left;
      right = p.right;
    }

    on eL2R do (m: tMsg) {
      toRight += (sizeof(toRight), m);
      schedule();
    }

    on eR2L do (m: tMsg) {
      toLeft += (sizeof(toLeft), m);
      schedule();
    }

    on eStep do {
      stepPending = false;
      deliverOne();
      schedule();
    }

    on eBreak do {
      toRight = default(seq[tMsg]);
      toLeft = default(seq[tMsg]);
      send left, eLinkLost, id;
      send right, eLinkLost, id;
    }
  }

  fun deliverOne() {
    var fromLeft: bool;
    if (sizeof(toRight) > 0 && sizeof(toLeft) > 0) {
      fromLeft = choose(2) == 0;
    } else {
      fromLeft = sizeof(toRight) > 0;
    }
    if (fromLeft) {
      send right, eInR, toRight[0];
      toRight -= (0);
    } else if (sizeof(toLeft) > 0) {
      send left, eInL, toLeft[0];
      toLeft -= (0);
    }
  }

  fun schedule() {
    if ((sizeof(toRight) > 0 || sizeof(toLeft) > 0) && !stepPending) {
      stepPending = true;
      send this, eStep;
    }
  }
}
