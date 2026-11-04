// The receiving node's store (`state_transfer.take` and `stage` over
// `state_store`).
//
// The durable parts are the half-written file, `part`, and the record, `stored`.
// A piece that starts at the end of `part` is appended. One inside it is a repeat
// and is accepted again with the length held, never written. One beyond it is
// refused with the length held, which is where the sender continues. The piece
// that reaches the declared size makes the state only if the whole of what was
// received is the described bundle; a mismatch discards the half-written file and
// stores nothing. A state that is already stored answers every piece with its
// whole size.
//
// A restart of the receiver loses nothing in memory, because the store keeps none.
// It can leave the half-written file shorter than it was, since a rename is not a
// flush, and the length it reports afterwards is the length it has.
machine Receiver {
  var wire: machine;
  var expected: seq[int];
  var size: int;
  var part: seq[int];
  var stored: bool;

  start state Init {
    entry (p: (wire: machine, expected: seq[int])) {
      wire = p.wire;
      expected = p.expected;
      size = sizeof(p.expected);
      goto Serving;
    }
  }

  state Serving {
    on eNetUp do (r: tRequest) {
      if (r.ask == ASK_STATUS) {
        status(r);
      } else {
        take(r);
      }
    }

    on eCrashReceiver do {
      crash();
    }
  }

  // How far the state has got: stored, or a prefix of some length.
  fun status(r: tRequest) {
    if (stored) {
      reply(r, A_COMPLETE, size);
    } else {
      reply(r, A_PARTIAL, sizeof(part));
    }
  }

  // Places one piece against the bytes held.
  fun take(r: tRequest) {
    var held: int;
    if (stored) {
      reply(r, A_ACCEPTED, size);
      return;
    }
    held = sizeof(part);
    if (r.offset == held) {
      part += (held, r.payload);
      announce ePart, (held = part, expected = expected);
      if (sizeof(part) == size) {
        finish(r);
      } else {
        reply(r, A_ACCEPTED, sizeof(part));
      }
      return;
    }
    if (r.offset > held) {
      reply(r, A_OUT_OF_ORDER, held);
      return;
    }
    announce eDuplicated;
    reply(r, A_ACCEPTED, held);
  }

  // The last piece landed. The record is written only for the described bytes.
  fun finish(r: tRequest) {
    if (part == expected) {
      stored = true;
      announce eStored, (held = part, expected = expected);
      part = default(seq[int]);
      reply(r, A_ACCEPTED, size);
    } else {
      part = default(seq[int]);
      reply(r, A_MISMATCH, 0);
    }
  }

  // A restart keeps a prefix of the half-written file, possibly all of it.
  fun crash() {
    var keep: int;
    var shorter: seq[int];
    var i: int;
    if (sizeof(part) == 0) {
      return;
    }
    keep = choose(sizeof(part) + 1);
    if (keep < sizeof(part)) {
      announce eTruncated;
    }
    i = 0;
    while (i < keep) {
      shorter += (sizeof(shorter), part[i]);
      i = i + 1;
    }
    part = shorter;
  }

  fun reply(r: tRequest, a: tAnswer, held: int) {
    send wire, eSendDown, (attempt = r.attempt, answer = a, held = held);
  }
}
