// The network between the sender and the receiver.
//
// Erlang orders messages per sender and receiver pair, so each direction keeps
// one queue, and each step delivers the head of either non-empty queue. A request
// and the reply to an earlier one are therefore free to cross, and a request the
// sender abandoned stays in flight behind the one that replaced it, which is how a
// retry comes to overlap its predecessor.
//
// A broken connection loses every message in flight in both directions and tells
// the sender once, which is the `PortGone` an exchange ends with. A message sent
// after the break travels normally, because Erlang reconnects on the next send.
machine Wire {
  var sender: machine;
  var receiver: machine;
  var up: seq[tRequest];
  var down: seq[tReply];
  var stepPending: bool;

  start state Running {
    on eWireEnds do (p: (sender: machine, receiver: machine)) {
      sender = p.sender;
      receiver = p.receiver;
    }

    on eSendUp do (r: tRequest) {
      up += (sizeof(up), r);
      schedule();
    }

    on eSendDown do (r: tReply) {
      down += (sizeof(down), r);
      schedule();
    }

    on eStep do {
      stepPending = false;
      deliverOne();
      schedule();
    }

    on eBreak do {
      up = default(seq[tRequest]);
      down = default(seq[tReply]);
      send sender, eNoConn;
    }
  }

  // Delivers the head of one non-empty queue, chosen by the scheduler.
  fun deliverOne() {
    var fromUp: bool;
    if (sizeof(up) > 0 && sizeof(down) > 0) {
      fromUp = choose(2) == 0;
    } else {
      fromUp = sizeof(up) > 0;
    }
    if (fromUp) {
      send receiver, eNetUp, up[0];
      up -= (0);
    } else if (sizeof(down) > 0) {
      send sender, eNetDown, down[0];
      down -= (0);
    }
  }

  // Keeps exactly one delivery step scheduled while anything is in flight.
  fun schedule() {
    if ((sizeof(up) > 0 || sizeof(down) > 0) && !stepPending) {
      stepPending = true;
      send this, eStep;
    }
  }
}
