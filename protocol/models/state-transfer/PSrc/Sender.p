// The sending end (`state_transfer.send` and the drainer that calls it again).
//
// A pass begins when the drainer pokes an idle sender: it asks where the receiver
// stands, then sends the piece at that offset and continues at the offset each
// verdict reports, until the receiver holds the whole state. A verdict that
// corrects the offset is followed a bounded number of times, and a pass that has
// pushed more pieces than the state needs plus that bound gives up. A pass that
// loses its connection, gives up early or is cut off by the sender's own restart
// ends without a result, and the next poke begins a new one. Nothing the sender
// remembers survives its restart but the transfer it owes and the count of
// passes, which only keeps a reply to an earlier pass from being taken for the
// current one.
machine Sender {
  var wire: machine;
  var content: seq[int];
  var size: int;
  var attempt: int;
  var offset: int;
  var pushed: int;
  var resyncs: int;
  var began: bool;

  start state Init {
    entry (p: (wire: machine, content: seq[int])) {
      wire = p.wire;
      content = p.content;
      size = sizeof(p.content);
      goto Idle;
    }
  }

  // Between passes. A poke begins one.
  state Idle {
    on ePoke do {
      begin();
    }

    ignore eNetDown, eNoConn, eGiveUp, eCrashSender;
  }

  // A pass has asked where the receiver stands.
  state Asking {
    on eNetDown do (r: tReply) {
      if (r.attempt != attempt) {
        return;
      }
      if (r.answer == A_COMPLETE) {
        delivered();
      } else {
        offset = r.held;
        push();
      }
    }

    on eNoConn do {
      abandon();
    }

    on eGiveUp do {
      abandon();
    }

    on eCrashSender do {
      abandon();
    }

    ignore ePoke;
  }

  // A pass has pushed a piece and waits for its verdict.
  state Pushing {
    on eNetDown do (r: tReply) {
      if (r.attempt != attempt) {
        return;
      }
      if (r.answer == A_ACCEPTED) {
        if (r.held >= size) {
          delivered();
        } else {
          offset = r.held;
          push();
        }
      } else if (r.answer == A_OUT_OF_ORDER) {
        resyncs = resyncs + 1;
        announce eResynced;
        if (resyncs > 8) {
          abandon();
        } else {
          offset = r.held;
          push();
        }
      } else if (r.answer == A_MISMATCH) {
        announce eDeclined;
        goto Done;
      }
    }

    on eNoConn do {
      abandon();
    }

    on eGiveUp do {
      abandon();
    }

    on eCrashSender do {
      abandon();
    }

    ignore ePoke;
  }

  // The receiver holds the state, or refused it for good.
  state Done {
    ignore ePoke, eNetDown, eNoConn, eGiveUp, eCrashSender;
  }

  fun begin() {
    attempt = attempt + 1;
    offset = 0;
    pushed = 0;
    resyncs = 0;
    if (!began) {
      began = true;
      announce eBegan;
    }
    send wire, eSendUp, (attempt = attempt, ask = ASK_STATUS, offset = 0, payload = 0);
    goto Asking;
  }

  // Sends the piece at the current offset, unless the pass has pushed more than the
  // state needs.
  fun push() {
    if (pushed >= size + 8) {
      abandon();
      return;
    }
    if (pushed == 0 && offset > 0) {
      announce eResumed, offset;
    }
    pushed = pushed + 1;
    send wire, eSendUp, (attempt = attempt, ask = ASK_PIECE, offset = offset, payload = content[offset]);
    goto Pushing;
  }

  fun delivered() {
    announce eDelivered;
    goto Done;
  }

  // The pass ends with no result. The drainer's next pass is the retry.
  fun abandon() {
    send this, ePoke;
    goto Idle;
  }
}
