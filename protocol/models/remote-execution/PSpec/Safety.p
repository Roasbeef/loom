// Independent history survives row GC. These monitors do not trust the row
// flags which the executor itself uses to authorize compaction.
spec AdmissionSafety observes mCustody, mAdmit, mAck, mGC, mClose, mAdvance, mAnswer, mRecovered {
  var custody: map[tKey, int];
  var admitted: map[tKey, int];
  var retained: set[tKey];
  var closedEpochs: set[tEpoch];
  var current: tEpoch;
  start state Watching {
    entry { current = (session = 1, workspace = 1); }
    on mCustody do (r: tRequest) { custody[r.key] = r.digest; }
    on mClose do (p: tEpoch) { closedEpochs += (p); }
    on mAdvance do (p: tEpoch) {
      assert current in closedEpochs, "epoch advanced without durable closure";
      assert p.session > current.session && p.workspace > current.workspace,
        "epoch high-water mark did not advance";
      current = p;
    }
    on mAdmit do (r: tRequest) {
      var ep: tEpoch;
      ep = (session = r.key.sessionEpoch, workspace = r.key.workspaceEpoch);
      assert r.key in custody && custody[r.key] == r.digest, "admission without owner custody";
      assert !(r.key in admitted), "same logical execution admitted again after GC";
      assert !(ep in closedEpochs) && ep == current, "old or closed admission epoch accepted";
      assert sizeof(retained) < 2, "durable evidence capacity exceeded";
      admitted[r.key] = r.digest;
      retained += (r.key);
    }
    on mAck do (r: tRequest) {
      assert r.key in retained && admitted[r.key] == r.digest,
        "admission acknowledged before durable matching row";
    }
    on mGC do (k: tKey) { retained -= (k); }
    on mAnswer do (p: tReply) {
      if (p.answer == Prior) {
        assert p.request.key in retained && p.row.request == p.request,
          "duplicate reply did not preserve prior durable request";
      }
      if (p.answer == Capacity) {
        assert sizeof(retained) == 2, "capacity refusal without full reserved ledger";
      }
      // Exact retained IDs still reconcile after closure and saturation.
      if (p.request.key in retained) {
        if (admitted[p.request.key] == p.request.digest) {
          assert p.answer == Prior, "closed epoch blocked same-ID reconciliation";
        } else {
          assert p.answer == Conflict, "changed digest did not conflict";
        }
      }
      if (p.answer == Conflict) {
        assert p.request.key in retained && admitted[p.request.key] != p.request.digest,
          "conflict without retained row and changed content";
      }
    }
    on mRecovered do (p: (boot: int, rows: map[tKey, tRow])) {
      var ks: seq[tKey];
      var i: int;
      assert sizeof(p.rows) == sizeof(retained), "restart lost durable row custody";
      ks = keys(p.rows);
      i = 0;
      while (i < sizeof(ks)) {
        assert ks[i] in retained && p.rows[ks[i]].request.digest == admitted[ks[i]],
          "restart changed execution identity or content";
        i = i + 1;
      }
    }
  }
}

spec LaunchSafety observes mAdmit, mIntent, mStart, mRecovered, mClose {
  var admitted: set[tKey];
  var intents: map[tKey, int];
  var started: set[tKey];
  var closedEpochs: set[tEpoch];
  start state Watching {
    on mAdmit do (r: tRequest) { admitted += (r.key); }
    on mClose do (p: tEpoch) { closedEpochs += (p); }
    on mIntent do (p: tNative) {
      assert !((session = p.key.sessionEpoch, workspace = p.key.workspaceEpoch) in closedEpochs),
        "closed epoch authorized a first launch";
      assert p.key in admitted, "launch intent without durable admission";
      assert !(p.key in intents), "uncertain launch was automatically retried";
      intents[p.key] = p.boot;
    }
    on mStart do (p: tNative) {
      assert p.key in intents && intents[p.key] == p.boot, "native start before durable launch intent";
      assert !(p.key in started), "logical execution launched twice";
      started += (p.key);
    }
    on mRecovered do (p: (boot: int, rows: map[tKey, tRow])) {
      var ks: seq[tKey];
      var i: int;
      ks = keys(p.rows);
      i = 0;
      while (i < sizeof(ks)) {
        if (ks[i] in intents) {
          assert p.rows[ks[i]].phase != Admitted && p.rows[ks[i]].launchBoot == intents[ks[i]],
            "restart erased uncertain launch evidence";
        }
        i = i + 1;
      }
    }
  }
}

spec ReceiptSafety observes mAdmit, mTerminal, mRetired, mOwnerStored, mReceipt, mGC, mClose, mAdvance, mRecovered {
  var retained: set[tKey];
  var terminal: set[tKey];
  var retired: set[tKey];
  var stored: map[tKey, int];
  var receipt: set[tKey];
  var closedEpochs: set[tEpoch];
  start state Watching {
    on mAdmit do (p: tRequest) { retained += (p.key); }
    on mTerminal do (k: tKey) { terminal += (k); }
    on mRetired do (k: tKey) { retired += (k); }
    on mOwnerStored do (p: tRequest) {
      assert p.key in terminal, "owner invented terminal evidence";
      stored[p.key] = p.digest;
    }
    on mReceipt do (p: tRequest) {
      assert p.key in stored && stored[p.key] == p.digest, "receipt preceded owner durable commit";
      receipt += (p.key);
    }
    on mClose do (p: tEpoch) { closedEpochs += (p); }
    on mGC do (k: tKey) {
      var ep: tEpoch;
      ep = (session = k.sessionEpoch, workspace = k.workspaceEpoch);
      assert k in terminal, "terminal GC without terminal outcome";
      assert k in retired, "terminal GC without native retirement";
      assert k in receipt, "terminal GC without owner durable receipt acknowledgement";
      assert ep in closedEpochs, "row GC reopened an unfenced execution identity";
      retained -= (k);
    }
    on mAdvance do (p: tEpoch) {
      assert sizeof(retained) == 0, "epoch advanced before outstanding rows were safe";
    }
    on mRecovered do (p: (boot: int, rows: map[tKey, tRow])) {
      var ks: seq[tKey];
      var i: int;
      ks = keys(p.rows);
      i = 0;
      while (i < sizeof(ks)) {
        if (ks[i] in terminal) { assert p.rows[ks[i]].phase == Terminal, "restart erased outcome"; }
        if (ks[i] in retired) { assert p.rows[ks[i]].retired, "restart erased native retirement"; }
        if (ks[i] in receipt) { assert p.rows[ks[i]].receipt, "restart erased receipt"; }
        i = i + 1;
      }
    }
  }
}

spec CancelSafety observes mCancelEffect {
  start state Watching {
    on mCancelEffect do (p: tCancelEffect) {
      assert p.asked == p.active, "stale cancel acted on reused helper's newer execution";
    }
  }
}

// The finite reliable scripts must finish. Lossy traffic intentionally has
// no progress event and no liveness claim.
spec DirectedProgress observes mScenarioBegin, mScenarioEnd {
  start cold state Idle {
    on mScenarioBegin goto Outstanding;
  }
  hot state Outstanding {
    on mScenarioEnd goto Finished;
  }
  cold state Finished { }
}
