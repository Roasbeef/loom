// Test cases and the environment.
//
// The `tc*` cases without `Probe` in the name must pass. The system cases check
// every spec over a mix of faults; the `tcOnly*` cases check one spec each over
// the same traffic, so a spec that stops depending on a rule is reported under
// the name of the rule. The `tcProbe*` cases must fail: each finds a witness for a
// situation the specs are only meaningful if the model reaches.

module System = { Wire, Sender, Receiver, Chaos, Harness };

fun honest(size: int): seq[int] {
  var s: seq[int];
  var i: int;
  i = 0;
  while (i < size) {
    s += (sizeof(s), 1);
    i = i + 1;
  }
  return s;
}

// The same bundle with its last piece replaced, which no hash would accept.
fun forgedOf(size: int): seq[int] {
  var s: seq[int];
  s = honest(size);
  s[size - 1] = 0;
  return s;
}

// The environment: breaks the connection, restarts the receiver, restarts the
// sender, and makes a pass give up while its request is still in flight, each as
// often as its budget allows and at times the scheduler chooses. Between actions
// it idles for a random number of its own steps, which spreads the faults over the
// whole run instead of spending them before the first message is sent. When the
// budgets are spent it does what the drainer does eventually: it pokes the sender
// on a quiet network.
machine Chaos {
  var wire: machine;
  var sender: machine;
  var receiver: machine;
  var breaks: int;
  var receiverCrashes: int;
  var senderCrashes: int;
  var giveUps: int;

  start state Init {
    entry (p: (wire: machine, sender: machine, receiver: machine, plan: tPlan)) {
      wire = p.wire;
      sender = p.sender;
      receiver = p.receiver;
      breaks = p.plan.breaks;
      receiverCrashes = p.plan.receiverCrashes;
      senderCrashes = p.plan.senderCrashes;
      giveUps = p.plan.giveUps;
      send this, eChaosStep;
      goto Acting;
    }
  }

  state Acting {
    on eChaosStep do {
      if (breaks + receiverCrashes + senderCrashes + giveUps == 0) {
        send sender, ePoke;
        send sender, ePoke;
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

  // Spends one unit of one budget.
  fun act() {
    var kinds: seq[int];
    var kind: int;
    if (breaks > 0) {
      kinds += (sizeof(kinds), 0);
    }
    if (receiverCrashes > 0) {
      kinds += (sizeof(kinds), 1);
    }
    if (senderCrashes > 0) {
      kinds += (sizeof(kinds), 2);
    }
    if (giveUps > 0) {
      kinds += (sizeof(kinds), 3);
    }
    kind = choose(kinds);
    if (kind == 0) {
      breaks = breaks - 1;
      send wire, eBreak;
    } else if (kind == 1) {
      receiverCrashes = receiverCrashes - 1;
      send wire, eBreak;
      send receiver, eCrashReceiver;
    } else if (kind == 2) {
      senderCrashes = senderCrashes - 1;
      send sender, eCrashSender;
    } else {
      giveUps = giveUps - 1;
      send sender, eGiveUp;
    }
  }
}

// Builds the machines for one plan and starts the transfer with a poke.
machine Harness {
  start state Init {
    entry (plan: tPlan) {
      var wire: machine;
      var sender: machine;
      var receiver: machine;
      var content: seq[int];
      wire = new Wire();
      receiver = new Receiver((wire = wire, expected = honest(plan.size)));
      if (plan.forged) {
        content = forgedOf(plan.size);
      } else {
        content = honest(plan.size);
      }
      sender = new Sender((wire = wire, content = content));
      send wire, eWireEnds, (sender = sender, receiver = receiver);
      send sender, ePoke;
      new Chaos((wire = wire, sender = sender, receiver = receiver, plan = plan));
    }
  }
}

machine TestQuiet {
  start state Init {
    entry {
      new Harness((size = 4, forged = false, breaks = 0, receiverCrashes = 0, senderCrashes = 0, giveUps = 0));
    }
  }
}

// Connections dropped in the middle of a transfer, with the next pass resuming
// from whatever the receiver holds.
machine TestDrops {
  start state Init {
    entry {
      new Harness((size = 4, forged = false, breaks = 3, receiverCrashes = 0, senderCrashes = 0, giveUps = 0));
    }
  }
}

// The receiver restarts in the middle, twice, and may come back with a shorter
// half-written file.
machine TestReceiverRestart {
  start state Init {
    entry {
      new Harness((size = 4, forged = false, breaks = 0, receiverCrashes = 2, senderCrashes = 0, giveUps = 0));
    }
  }
}

// The sender restarts in the middle, twice, and keeps nothing but the transfer it
// owes.
machine TestSenderRestart {
  start state Init {
    entry {
      new Harness((size = 4, forged = false, breaks = 0, receiverCrashes = 0, senderCrashes = 2, giveUps = 0));
    }
  }
}

// A pass gives up while its request is in flight, so the next pass's requests
// follow the abandoned ones and pieces arrive twice and out of order.
machine TestOverlap {
  start state Init {
    entry {
      new Harness((size = 4, forged = false, breaks = 0, receiverCrashes = 0, senderCrashes = 0, giveUps = 3));
    }
  }
}

// Every fault together.
machine TestAll {
  start state Init {
    entry {
      new Harness((size = 4, forged = false, breaks = 2, receiverCrashes = 1, senderCrashes = 1, giveUps = 2));
    }
  }
}

// A sender whose bundle is not the one described, with the faults that make a
// transfer start over: the bytes are refused at the last piece and nothing is
// named by a record.
machine TestForged {
  start state Init {
    entry {
      new Harness((size = 4, forged = true, breaks = 1, receiverCrashes = 1, senderCrashes = 0, giveUps = 1));
    }
  }
}

test tcQuiet [main = TestQuiet]:
  assert OnlyTheDescribedBytesAreStored, PartIsAlwaysAPrefix, DeliveredOnlyAfterStored, EveryTransferEnds in
  (union System, { TestQuiet });

test tcDrops [main = TestDrops]:
  assert OnlyTheDescribedBytesAreStored, PartIsAlwaysAPrefix, DeliveredOnlyAfterStored, EveryTransferEnds in
  (union System, { TestDrops });

test tcReceiverRestart [main = TestReceiverRestart]:
  assert OnlyTheDescribedBytesAreStored, PartIsAlwaysAPrefix, DeliveredOnlyAfterStored, EveryTransferEnds in
  (union System, { TestReceiverRestart });

test tcSenderRestart [main = TestSenderRestart]:
  assert OnlyTheDescribedBytesAreStored, PartIsAlwaysAPrefix, DeliveredOnlyAfterStored, EveryTransferEnds in
  (union System, { TestSenderRestart });

test tcOverlap [main = TestOverlap]:
  assert OnlyTheDescribedBytesAreStored, PartIsAlwaysAPrefix, DeliveredOnlyAfterStored, EveryTransferEnds in
  (union System, { TestOverlap });

test tcAll [main = TestAll]:
  assert OnlyTheDescribedBytesAreStored, PartIsAlwaysAPrefix, DeliveredOnlyAfterStored, EveryTransferEnds in
  (union System, { TestAll });

test tcForged [main = TestForged]:
  assert OnlyTheDescribedBytesAreStored, DeliveredOnlyAfterStored, EveryTransferEnds in
  (union System, { TestForged });

test tcOnlyStoredBytes [main = TestForged]:
  assert OnlyTheDescribedBytesAreStored in (union System, { TestForged });

test tcOnlyPrefix [main = TestAll]:
  assert PartIsAlwaysAPrefix in (union System, { TestAll });

test tcOnlyDelivery [main = TestAll]:
  assert DeliveredOnlyAfterStored in (union System, { TestAll });

test tcOnlyEnds [main = TestAll]:
  assert EveryTransferEnds in (union System, { TestAll });

test tcProbeResumed [main = TestDrops]:
  assert ProbeResumed in (union System, { TestDrops });

test tcProbeTruncated [main = TestReceiverRestart]:
  assert ProbeTruncated in (union System, { TestReceiverRestart });

test tcProbeDeclined [main = TestForged]:
  assert ProbeDeclined in (union System, { TestForged });
