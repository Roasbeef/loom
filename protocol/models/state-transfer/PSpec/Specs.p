// The properties the model checks. Each spec is named after the rule it
// encodes, and the comment above it cites where that rule lives. The rules come
// from protocol-change/107, "Send", and from `client/state_transfer`.

// Whether `part` is a prefix of `whole`.
fun isPrefix(part: seq[int], whole: seq[int]): bool {
  var i: int;
  if (sizeof(part) > sizeof(whole)) {
    return false;
  }
  i = 0;
  while (i < sizeof(part)) {
    if (part[i] != whole[i]) {
      return false;
    }
    i = i + 1;
  }
  return true;
}

// A record names a state only if the bytes received are the described bundle.
// `state_store.finish` compares the size and the SHA-256 with the description
// before it renames the bundle into place and writes the record, and a mismatch
// discards the half-written file. A forged sender, a restart in the middle and a
// retry that overlaps its predecessor cannot change that.
spec OnlyTheDescribedBytesAreStored observes eStored {
  start state Watching {
    on eStored do (p: (held: seq[int], expected: seq[int])) {
      assert p.held == p.expected, "a record names bytes that are not the described state";
    }
  }
}

// What the receiver holds half-written is always a prefix of the bundle, however
// the pieces arrive. A piece is appended only at the end of what is held
// (`state_transfer.placed`), a repeat is not written, and a gap is refused, so
// duplicates, retries that overlap and a restart that shortens the file leave a
// prefix. This holds for an honest sender; a forged one writes bytes that are not
// the bundle's, which the last piece's comparison refuses.
spec PartIsAlwaysAPrefix observes ePart {
  start state Watching {
    on ePart do (p: (held: seq[int], expected: seq[int])) {
      assert isPrefix(p.held, p.expected), "the half-written file is not a prefix of the bundle";
    }
  }
}

// The sender concludes `Delivered` only after a record names the state. It
// concludes from a status that says `Complete` or from a verdict that holds the
// whole size, and the receiver gives either only for a stored state.
spec DeliveredOnlyAfterStored observes eStored, eDelivered {
  var stored: bool;

  start state Watching {
    on eStored do (p: (held: seq[int], expected: seq[int])) {
      stored = true;
    }

    on eDelivered do {
      assert stored, "the sender concluded delivery before any record named the state";
    }
  }
}

// A transfer that begins ends: the receiver holds the state, or refuses it for
// good. Dropped connections, a restart of either end and a pass that gives up are
// repaired by asking again where the receiver stands, so bounded faults delay the
// end and cannot lose it. P reports a violation when a run ends with the monitor
// in the hot state.
spec EveryTransferEnds observes eBegan, eDelivered, eDeclined {
  start cold state Quiet {
    on eBegan goto Waiting;
  }

  hot state Waiting {
    on eDelivered goto Over;
    on eDeclined goto Over;
  }

  cold state Over {
    ignore eBegan, eDelivered, eDeclined;
  }
}
