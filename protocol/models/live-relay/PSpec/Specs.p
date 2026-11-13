// The properties the model checks, from protocol-change/108, "The P model" in the
// test plan. Each spec observes events the machines announce and says nothing
// about how they work.

// Every frame the gateway wrote to the feed reaches the lane at most once and in
// the gateway's order. A delivered sequence of gateway frames is the written
// sequence with nothing skipped and nothing repeated, so with a lapse it is a
// prefix of the written frames. A frame the feed host wrote itself (gid from
// 1001) is held to at most once. A gap in the box's numbering, which the
// laptop's adapter reports, means the box dropped a frame before the laptop
// acknowledged it, and is a violation: an honest box never produces one.
spec FeedOrderedAtMostOnce observes eWritten, eDelivered, eGapObserved {
  var written: seq[int];
  var delivered: set[int];
  var next: int;

  start state Watching {
    on eWritten do (gid: int) {
      written += (sizeof(written), gid);
    }

    on eDelivered do (p: (gid: int, endAnswer: int)) {
      assert !(p.gid in delivered), format("frame {0} reached the lane twice", p.gid);
      delivered += (p.gid);
      if (p.gid < 1000) {
        assert next < sizeof(written) && written[next] == p.gid, format("frame {0} reached the lane out of the gateway's order", p.gid);
        next = next + 1;
      }
    }

    on eGapObserved do {
      assert false, "the box dropped a frame before the laptop acknowledged it";
    }
  }
}

// Every frame the lane transmitted reaches the gateway at most once and whole.
// The gateway counts a frame when the feed host hands it over, with the number of
// pieces the feed host admitted for it.
spec LaneFrameOnceWhole observes eLaneTx, eGwReceived {
  var transmitted: set[int];
  var received: set[int];

  start state Watching {
    on eLaneTx do (n: int) {
      transmitted += (n);
    }

    on eGwReceived do (p: (n: int, pieces: int, total: int, cmd: tCmd)) {
      assert p.n in transmitted, format("the gateway received frame {0}, which the lane did not transmit", p.n);
      assert !(p.n in received), format("the gateway received frame {0} twice", p.n);
      assert p.pieces == p.total, format("the gateway received frame {0} with {1} of {2} pieces", p.n, p.pieces, p.total);
      received += (p.n);
    }
  }
}

// After a feed ends, no frame of it reaches a lane. Frames of an answer the box
// sent before the end may still arrive: they were written before it, and the
// order property covers them. So the property is stated at the two places the
// end is visible. The feed host sends no frame once it has ended, and the
// laptop delivers no frame from an answer that reports the feed ended.
spec NothingAfterEnd observes eAnswerSent, eDelivered {
  start state Watching {
    on eAnswerSent do (p: (count: int, hostEnded: int)) {
      assert !(p.hostEnded == 1 && p.count > 0), "the feed host answered frames after its feed ended";
    }

    on eDelivered do (p: (gid: int, endAnswer: int)) {
      assert p.endAnswer == 0, format("frame {0} reached the lane in an answer that reports the feed ended", p.gid);
    }
  }
}

// A decision reaches the hub only through the relayed door. The feed host must
// not call the hub's local door, and a command outside the filter's forwarding
// rows (an approval or a forbidden command) must not reach the gateway as a
// frame. The box owner's own approve uses the local door, and that is allowed.
spec RelayedDoorOnly observes eFeedStarted, eDecided, eGwReceived {
  var feed: machine;

  start state Watching {
    on eFeedStarted do (h: machine) {
      feed = h;
    }

    on eDecided do (p: (door: tDoor, caller: machine)) {
      assert !(p.door == DOOR_LOCAL && p.caller == feed), "the feed host called the hub's local door";
      assert !(p.door == DOOR_RELAYED && p.caller != feed), "the relayed door was called by something other than the feed host";
    }

    on eGwReceived do (p: (n: int, pieces: int, total: int, cmd: tCmd)) {
      assert p.cmd == CMD_FORWARD, format("a command outside the forwarding rows reached the gateway as frame {0}", p.n);
    }
  }
}

// A link that is only down shows waiting and never a failure. When the adapter
// closes the page because the lane failed, a page whose link is cut at that
// moment must show the waiting state. The partition is observed at the link, not
// in the adapter, so the adapter cannot excuse itself.
spec DownShowsWaiting observes eCut, eHealed, eShown {
  var cut: int;

  start state Watching {
    on eCut do {
      cut = 1;
    }

    on eHealed do {
      cut = 0;
    }

    on eShown do (k: tShown) {
      assert !(cut == 1 && k == SH_FAILED), "the page showed a failure for a link that was only down";
    }
  }
}

// Liveness. The scenario's premise is a partition shorter than the lease, during
// which no lane deadline passes: the test case announces it with
// `eShortPartition` and sets the lane's deadline above the longest recovery. Given
// that, the feed does not lapse, the lane does not fail, and every frame the
// gateway wrote reaches the lane. A lapse or a lane failure in such a run is
// reported as a violation of the premise's consequence, not excused.
//
// `Pending` is the hot state: a frame was written and not yet delivered. A run
// that ends there is a liveness failure.
spec ShortPartitionLosesNothing observes eShortPartition, eWritten, eDelivered, eFeedEnded, eLaneFailed {
  var written: set[int];
  var delivered: set[int];

  start state Idle {
    on eShortPartition goto Watching;
    ignore eWritten, eDelivered, eFeedEnded, eLaneFailed;
  }

  cold state Watching {
    on eWritten do (gid: int) {
      written += (gid);
      goto Pending;
    }

    on eDelivered do (p: (gid: int, endAnswer: int)) {
      delivered += (p.gid);
    }

    on eFeedEnded do (k: tEnded) {
      assert false, "the feed ended during a partition shorter than the lease";
    }

    on eLaneFailed do {
      assert false, "the lane failed in a run whose partition was shorter than its deadline";
    }
  }

  hot state Pending {
    on eWritten do (gid: int) {
      written += (gid);
    }

    on eDelivered do (p: (gid: int, endAnswer: int)) {
      delivered += (p.gid);
      if (outstanding() == 0) {
        goto Settled;
      }
    }

    on eFeedEnded do (k: tEnded) {
      assert false, "the feed ended during a partition shorter than the lease";
    }

    on eLaneFailed do {
      assert false, "the lane failed in a run whose partition was shorter than its deadline";
    }
  }

  cold state Settled {
    on eWritten do (gid: int) {
      written += (gid);
      goto Pending;
    }

    on eDelivered do (p: (gid: int, endAnswer: int)) {
      delivered += (p.gid);
    }

    on eFeedEnded do (k: tEnded) {
      assert false, "the feed ended during a partition shorter than the lease";
    }

    on eLaneFailed do {
      assert false, "the lane failed in a run whose partition was shorter than its deadline";
    }
  }

  fun outstanding(): int {
    var g: int;
    var n: int;
    foreach (g in written) {
      if (!(g in delivered)) {
        n = n + 1;
      }
    }
    return n;
  }
}

// Every ending of a feed detaches the gateway door exactly once: a lapse by the
// bound or the lease, the page's detach, a stop and a revocation. The feed
// announces its ending before it sends the detach, so a detach with no ending
// owed, which is a second detach for one ending, is a violation, and an ending
// whose detach never arrives leaves the spec in its hot state.
spec EveryEndingDetachesOnce observes eFeedEnded, eGwDetached {
  var endings: int;
  var detaches: int;

  start state Even {
    on eFeedEnded do (k: tEnded) {
      endings = endings + 1;
      goto Owing;
    }

    on eGwDetached do {
      assert false, "the gateway door was detached with no ending owed, or twice for one ending";
    }
  }

  hot state Owing {
    on eFeedEnded do (k: tEnded) {
      endings = endings + 1;
    }

    on eGwDetached do {
      detaches = detaches + 1;
      if (detaches == endings) {
        goto Even;
      }
    }
  }
}

// The feeds of one spawner never outnumber the cap. A feed is alive from the
// moment it runs until its process exits, which is when it is forgotten or when
// the page detaches, and an ended feed is alive until then. The directory counts
// a place for exactly that long, so a feed that ends and is kept still holds its
// place and a new feed is refused.
spec CapNeverExceeded observes eFeedStarted, eFeedExited {
  var alive: int;

  start state Watching {
    on eFeedStarted do (h: machine) {
      alive = alive + 1;
      assert alive <= Cap(), "more feeds are alive than the cap allows";
    }

    on eFeedExited do {
      alive = alive - 1;
    }
  }
}
