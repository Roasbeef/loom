// Test cases.
//
// The `tc*` cases without `Probe` in the name must pass. The system cases check
// every spec over one plan; the `tcOnly*` cases check one spec each, so a
// mutation (mutate.py) is reported under the name of the rule it breaks.
//
// The `tcProbe*` cases must fail: each finds a witness for a situation the specs
// are only meaningful if the model reaches.
//
// Every plan runs the Clock with `settle` of 10, so a tick never overtakes a
// message in flight, except TestRacing, which ticks with no settling.

module System = { Gateway, FeedHost, Link, UiFeed, Lane, Clock, Harness };

fun emit(at: int, size: int): tEmit {
  return (at = at, size = size);
}

fun cmdAt(at: int, cmd: tCmd, pieces: int): tCmdAt {
  return (at = at, cmd = cmd, pieces = pieces);
}

// A plan with no faults and nothing to do. The cases below edit a copy.
fun quietPlan(): tPlan {
  var e: seq[tEmit];
  var c: seq[tCmdAt];
  return (ticks = 10, settle = 10, emits = e, cmds = c, breakAt = -1, healAt = -1, closeAt = -1, stopAt = -1, revokeAt = -1, ownerAt = -1, laneDeadline = 8, loses = 0, dups = 0, delays = 0, short = 0);
}

// Pushes of two sizes and one command of each kind, a command of two pieces, the
// box owner approving at the local door, and the page closing at the end.
fun trafficPlan(): tPlan {
  var p: tPlan;
  p = quietPlan();
  p.ticks = 14;
  p.emits += (0, emit(0, 1));
  p.emits += (1, emit(1, 2));
  p.emits += (2, emit(3, 1));
  p.emits += (3, emit(5, 1));
  p.cmds += (0, cmdAt(1, CMD_FORWARD, 2));
  p.cmds += (1, cmdAt(2, CMD_APPROVE, 1));
  p.cmds += (2, cmdAt(3, CMD_FORBID, 1));
  p.cmds += (3, cmdAt(4, CMD_FORWARD, 1));
  p.ownerAt = 6;
  p.closeAt = 12;
  return p;
}

// A normal run: no faults.
machine TestNormal {
  start state Init {
    entry {
      new Harness(trafficPlan());
    }
  }
}

// A lossy link: answers and requests lost, answers duplicated, messages delayed
// past a tick. Some runs fail the lane at its deadline, and the safety
// properties must hold in all of them.
machine TestLossy {
  start state Init {
    entry {
      var p: tPlan;
      p = trafficPlan();
      p.ticks = 30;
      p.loses = 5;
      p.dups = 4;
      p.delays = 3;
      p.laneDeadline = 20;
      p.closeAt = -1;
      new Harness(p);
    }
  }
}

// Ticks that overtake messages, with loss, duplication and delay together.
machine TestRacing {
  start state Init {
    entry {
      var p: tPlan;
      p = trafficPlan();
      p.settle = 0;
      p.ticks = 40;
      p.loses = 3;
      p.dups = 3;
      p.delays = 3;
      p.laneDeadline = 30;
      p.closeAt = -1;
      new Harness(p);
    }
  }
}

// A partition of four ticks, shorter than the lease, with pushes written inside
// it and a command sent before it. No lane deadline passes. Every frame written
// reaches the lane after the heal.
machine TestShortPartition {
  start state Init {
    entry {
      var p: tPlan;
      p = quietPlan();
      p.ticks = 26;
      p.emits += (0, emit(0, 1));
      p.emits += (1, emit(2, 1));
      p.emits += (2, emit(3, 1));
      p.emits += (3, emit(6, 1));
      p.emits += (4, emit(9, 1));
      p.cmds += (0, cmdAt(1, CMD_FORWARD, 2));
      p.breakAt = 2;
      p.healAt = 6;
      p.laneDeadline = 40;
      p.short = 1;
      new Harness(p);
    }
  }
}

// A partition long enough that four frames pass the frame bound while no poll
// can acknowledge any, so the feed lapses. The poll after the heal learns it.
machine TestBoundLapse {
  start state Init {
    entry {
      var p: tPlan;
      p = quietPlan();
      p.ticks = 22;
      p.emits += (0, emit(2, 1));
      p.emits += (1, emit(2, 1));
      p.emits += (2, emit(2, 1));
      p.emits += (3, emit(2, 1));
      p.emits += (4, emit(3, 1));
      p.cmds += (0, cmdAt(1, CMD_FORWARD, 2));
      p.breakAt = 1;
      p.healAt = 7;
      new Harness(p);
    }
  }
}

// A frame larger than the byte bound goes to an empty queue and is delivered.
// It ends no feed.
machine TestOversize {
  start state Init {
    entry {
      var p: tPlan;
      p = quietPlan();
      p.ticks = 12;
      p.emits += (0, emit(2, 5));
      p.emits += (1, emit(5, 1));
      p.emits += (2, emit(7, 5));
      new Harness(p);
    }
  }
}

// An oversized frame in the queue, then another frame while the first is not
// acknowledged: the bytes pass the bound and the feed lapses.
machine TestByteLapse {
  start state Init {
    entry {
      var p: tPlan;
      p = quietPlan();
      p.ticks = 20;
      p.emits += (0, emit(2, 5));
      p.emits += (1, emit(3, 1));
      p.breakAt = 1;
      p.healAt = 6;
      new Harness(p);
    }
  }
}

// A partition longer than the lease, then a heal after the ended token was
// forgotten, so the poll that gets through is refused as feed_ended.
machine TestLeaseLapse {
  start state Init {
    entry {
      var p: tPlan;
      p = quietPlan();
      p.ticks = 34;
      p.emits += (0, emit(0, 1));
      p.emits += (1, emit(3, 1));
      p.breakAt = 2;
      p.healAt = 26;
      p.laneDeadline = 6;
      new Harness(p);
    }
  }
}

// The session stops while frames and commands are in flight.
machine TestStop {
  start state Init {
    entry {
      var p: tPlan;
      p = trafficPlan();
      p.ticks = 12;
      p.stopAt = 4;
      p.closeAt = -1;
      new Harness(p);
    }
  }
}

// The spawner's access is revoked while frames and commands are in flight.
machine TestRevoke {
  start state Init {
    entry {
      var p: tPlan;
      p = trafficPlan();
      p.ticks = 12;
      p.revokeAt = 4;
      p.closeAt = -1;
      new Harness(p);
    }
  }
}

// The page detaches, and detaches again, while the lane has a command out.
machine TestDetach {
  start state Init {
    entry {
      var p: tPlan;
      p = trafficPlan();
      p.ticks = 16;
      p.closeAt = 3;
      new Harness(p);
    }
  }
}

// An approval and its repeats through a link that loses and duplicates, for the
// decision door property.
machine TestApprovals {
  start state Init {
    entry {
      var p: tPlan;
      p = quietPlan();
      p.ticks = 24;
      p.cmds += (0, cmdAt(0, CMD_APPROVE, 2));
      p.cmds += (1, cmdAt(1, CMD_APPROVE, 1));
      p.cmds += (2, cmdAt(2, CMD_FORBID, 1));
      p.ownerAt = 3;
      p.loses = 4;
      p.dups = 4;
      p.delays = 2;
      p.laneDeadline = 20;
      new Harness(p);
    }
  }
}

// Frames of two pieces through a link that loses and duplicates answers, so a
// piece is resent after its answer was lost or a request arrives twice.
machine TestPieces {
  start state Init {
    entry {
      var p: tPlan;
      p = quietPlan();
      p.ticks = 30;
      p.cmds += (0, cmdAt(0, CMD_FORWARD, 2));
      p.cmds += (1, cmdAt(0, CMD_FORWARD, 2));
      p.cmds += (2, cmdAt(1, CMD_FORWARD, 1));
      p.loses = 4;
      p.dups = 5;
      p.delays = 2;
      p.laneDeadline = 24;
      new Harness(p);
    }
  }
}

// Every safety spec together.
test tcNormal [main = TestNormal]:
  assert FeedOrderedAtMostOnce, LaneFrameOnceWhole, NothingAfterEnd, RelayedDoorOnly in
  (union System, { TestNormal });

test tcLossy [main = TestLossy]:
  assert FeedOrderedAtMostOnce, LaneFrameOnceWhole, NothingAfterEnd, RelayedDoorOnly in
  (union System, { TestLossy });

test tcRacing [main = TestRacing]:
  assert FeedOrderedAtMostOnce, LaneFrameOnceWhole, NothingAfterEnd, RelayedDoorOnly in
  (union System, { TestRacing });

test tcShortPartition [main = TestShortPartition]:
  assert FeedOrderedAtMostOnce, LaneFrameOnceWhole, NothingAfterEnd, RelayedDoorOnly, ShortPartitionLosesNothing in
  (union System, { TestShortPartition });

test tcBoundLapse [main = TestBoundLapse]:
  assert FeedOrderedAtMostOnce, LaneFrameOnceWhole, NothingAfterEnd, RelayedDoorOnly in
  (union System, { TestBoundLapse });

test tcOversize [main = TestOversize]:
  assert FeedOrderedAtMostOnce, LaneFrameOnceWhole, NothingAfterEnd, RelayedDoorOnly in
  (union System, { TestOversize });

test tcByteLapse [main = TestByteLapse]:
  assert FeedOrderedAtMostOnce, LaneFrameOnceWhole, NothingAfterEnd, RelayedDoorOnly in
  (union System, { TestByteLapse });

test tcLeaseLapse [main = TestLeaseLapse]:
  assert FeedOrderedAtMostOnce, LaneFrameOnceWhole, NothingAfterEnd, RelayedDoorOnly in
  (union System, { TestLeaseLapse });

test tcStop [main = TestStop]:
  assert FeedOrderedAtMostOnce, LaneFrameOnceWhole, NothingAfterEnd, RelayedDoorOnly in
  (union System, { TestStop });

test tcRevoke [main = TestRevoke]:
  assert FeedOrderedAtMostOnce, LaneFrameOnceWhole, NothingAfterEnd, RelayedDoorOnly in
  (union System, { TestRevoke });

test tcDetach [main = TestDetach]:
  assert FeedOrderedAtMostOnce, LaneFrameOnceWhole, NothingAfterEnd, RelayedDoorOnly in
  (union System, { TestDetach });

test tcApprovals [main = TestApprovals]:
  assert FeedOrderedAtMostOnce, LaneFrameOnceWhole, NothingAfterEnd, RelayedDoorOnly in
  (union System, { TestApprovals });

test tcPieces [main = TestPieces]:
  assert FeedOrderedAtMostOnce, LaneFrameOnceWhole, NothingAfterEnd, RelayedDoorOnly in
  (union System, { TestPieces });

// One spec each, for mutate.py.
test tcOnlyOrderedAtMostOnce [main = TestLossy]:
  assert FeedOrderedAtMostOnce in (union System, { TestLossy });

test tcOnlyOnceWhole [main = TestPieces]:
  assert LaneFrameOnceWhole in (union System, { TestPieces });

test tcOnlyNothingAfterEnd [main = TestBoundLapse]:
  assert NothingAfterEnd in (union System, { TestBoundLapse });

test tcOnlyRelayedDoor [main = TestApprovals]:
  assert RelayedDoorOnly in (union System, { TestApprovals });

test tcOnlyShortPartition [main = TestShortPartition]:
  assert ShortPartitionLosesNothing in (union System, { TestShortPartition });

// Each of these must report a bug.
test tcProbeLapseBound [main = TestBoundLapse]:
  assert ProbeLapseBound in (union System, { TestBoundLapse });

test tcProbeEndedAnswer [main = TestBoundLapse]:
  assert ProbeEndedAnswer in (union System, { TestBoundLapse });

test tcProbeLapseByte [main = TestByteLapse]:
  assert ProbeLapseBound in (union System, { TestByteLapse });

test tcProbeLapseLease [main = TestLeaseLapse]:
  assert ProbeLapseLease in (union System, { TestLeaseLapse });

test tcProbeOversizeAdmitted [main = TestOversize]:
  assert ProbeOversizeAdmitted in (union System, { TestOversize });

test tcProbeSuperseded [main = TestRacing]:
  assert ProbeSuperseded in (union System, { TestRacing });

test tcProbeRepeatPiece [main = TestPieces]:
  assert ProbeRepeatPiece in (union System, { TestPieces });

test tcProbeRefusedForgotten [main = TestLeaseLapse]:
  assert ProbeRefusedForgotten in (union System, { TestLeaseLapse });

test tcProbeStopped [main = TestStop]:
  assert ProbeStopped in (union System, { TestStop });

test tcProbeRevoked [main = TestRevoke]:
  assert ProbeRevoked in (union System, { TestRevoke });

test tcProbeDetached [main = TestDetach]:
  assert ProbeDetached in (union System, { TestDetach });

test tcProbeRelayedDecision [main = TestNormal]:
  assert ProbeRelayedDecision in (union System, { TestNormal });

test tcProbeGatewayReceived [main = TestNormal]:
  assert ProbeGatewayReceived in (union System, { TestNormal });

test tcProbeLaneFailed [main = TestLossy]:
  assert ProbeLaneFailed in (union System, { TestLossy });

test tcProbePartitionDropped [main = TestShortPartition]:
  assert ProbePartitionDropped in (union System, { TestShortPartition });
