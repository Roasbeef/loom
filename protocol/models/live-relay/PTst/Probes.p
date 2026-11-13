// Reachability probes. Each probe asserts that one situation never happens, so a
// probe "failing" is the checker finding a witness that the model reaches the
// situation. They guard against a vacuous model: a spec that passes only
// because the situation it constrains is unreachable proves nothing. Every
// tcProbe* case is expected to report a bug.

// The queue passed its frame or byte bound and the feed lapsed.
spec ProbeLapseBound observes eLapse {
  start state Watching {
    on eLapse do (cause: int) {
      assert cause != 0, "witness: a feed lapsed because its queue passed the bound";
    }
  }
}

// A poll was answered after the feed ended, so a late poll learned why.
spec ProbeEndedAnswer observes eAnswerSent {
  start state Watching {
    on eAnswerSent do (p: (count: int, hostEnded: int)) {
      assert p.hostEnded == 0, "witness: a poll was answered after its feed ended";
    }
  }
}

// The lease passed with no poll and the feed lapsed.
spec ProbeLapseLease observes eLapse {
  start state Watching {
    on eLapse do (cause: int) {
      assert cause != 1, "witness: a feed lapsed because the lease passed";
    }
  }
}

// A frame larger than the byte bound was admitted to an empty queue.
spec ProbeOversizeAdmitted observes eAdmitted {
  start state Watching {
    on eAdmitted do (p: (gid: int, size: int)) {
      assert p.size <= MaxBytes(), "witness: an oversized frame was admitted to an empty queue";
    }
  }
}

// A second poll released a held poll.
spec ProbeSuperseded observes eSuperseded {
  start state Watching {
    on eSuperseded do {
      assert false, "witness: a poll superseded a held poll";
    }
  }
}

// A piece the box had already admitted was answered again.
spec ProbeRepeatPiece observes eRepeatPiece {
  start state Watching {
    on eRepeatPiece do {
      assert false, "witness: a repeated piece was answered again";
    }
  }
}

// An ended token was forgotten and a later poll was refused.
spec ProbeRefusedForgotten observes eRefusedForgotten {
  start state Watching {
    on eRefusedForgotten do {
      assert false, "witness: a poll for a forgotten token was refused";
    }
  }
}

// The session stopped and ended the feed.
spec ProbeStopped observes eFeedEnded {
  start state Watching {
    on eFeedEnded do (k: tEnded) {
      assert k != EN_STOPPED, "witness: a feed ended because its session stopped";
    }
  }
}

// Access was revoked and ended the feed.
spec ProbeRevoked observes eFeedEnded {
  start state Watching {
    on eFeedEnded do (k: tEnded) {
      assert k != EN_REVOKED, "witness: a feed ended because access was revoked";
    }
  }
}

// The page detached.
spec ProbeDetached observes eFeedEnded {
  start state Watching {
    on eFeedEnded do (k: tEnded) {
      assert k != EN_DETACHED, "witness: a feed ended because the page detached";
    }
  }
}

// A decision reached the hub through the relayed door.
spec ProbeRelayedDecision observes eDecided {
  start state Watching {
    on eDecided do (p: (door: tDoor, caller: machine)) {
      assert p.door != DOOR_RELAYED, "witness: a decision reached the hub through the relayed door";
    }
  }
}

// A lane frame reached the gateway.
spec ProbeGatewayReceived observes eGwReceived {
  start state Watching {
    on eGwReceived do (p: (n: int, pieces: int, total: int, cmd: tCmd)) {
      assert p.pieces < 2, "witness: a frame of two pieces reached the gateway";
    }
  }
}

// A lane failed at its deadline.
spec ProbeLaneFailed observes eLaneFailed {
  start state Watching {
    on eLaneFailed do {
      assert false, "witness: a lane failed";
    }
  }
}

// The link lost a message to a partition.
spec ProbePartitionDropped observes eLinkDropped {
  start state Watching {
    on eLinkDropped do {
      assert false, "witness: the link dropped a message in a partition";
    }
  }
}

// The adapter closed the page and showed the waiting state.
spec ProbeShownWaiting observes eShown {
  start state Watching {
    on eShown do (k: tShown) {
      assert k != SH_WAITING, "witness: the page showed the waiting state";
    }
  }
}

// The adapter closed the page and showed a failure.
spec ProbeShownFailed observes eShown {
  start state Watching {
    on eShown do (k: tShown) {
      assert k != SH_FAILED, "witness: the page showed a failure";
    }
  }
}

// The adapter dropped the frames of an answer that reported the feed ended.
spec ProbeDroppedEnded observes eDroppedEnded {
  start state Watching {
    on eDroppedEnded do {
      assert false, "witness: the frames of an ended answer were dropped";
    }
  }
}
