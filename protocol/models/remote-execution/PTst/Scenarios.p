// Real messages drive two executions through one native helper slot, a
// delayed old cancel, receipt, row GC, epoch advance and post-GC retries.
machine Lifecycle {
  var owner: machine;
  var executor: machine;
  var helper: machine;
  var stage: int;
  var first: tRequest;
  var second: tRequest;
  start state Init {
    entry (mode: tMode) {
      announce mScenarioBegin;
      executor = new Executor((driver = this, mode = mode));
      helper = new Helper();
      owner = new Owner((driver = this, executor = executor, mode = mode));
      send executor, eConnect, (owner = owner, helper = helper);
      send helper, eHelperConnect, executor;
      first = request(1, 1, 1);
      second = request(2, 1, 1);
      send owner, ePrepare, first;
      goto Driving;
    }
  }
  state Driving {
    on eView do (p: tReply) {
      var changed: tRequest;
      if (stage == 0 && p.answer == Prior && p.row.phase == Running) {
        stage = 1;
        // Admission of this cancel precedes first's retirement, while
        // delivery to the native slot is delayed until second is running.
        send owner, eOwnerCancel, first;
      } else if (stage == 1 && p.answer == Prior && p.row.phase == Running) {
        stage = 17;
        send executor, eCrash;
      } else if (stage == 2 && p.answer == Prior && p.row.phase == Terminal) {
        assert p.row.outcome == Succeeded, "first execution did not succeed";
        stage = 3;
        send owner, eOwnerReceipt, first;
        send helper, eRetireNative;
      } else if (stage == 3 && p.answer == Prior && rowSafe(p.row)) {
        stage = 4;
        send owner, ePrepare, second;
      } else if (stage == 4 && p.request == second && p.answer == Prior && p.row.phase == Running) {
        stage = 5;
        send helper, eDeliverCancel;
        send owner, ePrepare, request(3, 1, 1);
        changed = second;
        changed.digest = 2;
        send owner, eRetry, changed;
        send helper, eFinishNative;
      } else if (stage == 5 && p.request == second && p.answer == Prior && p.row.phase == Terminal) {
        assert p.row.outcome == Succeeded, "second execution did not succeed";
        stage = 6;
        send owner, eOwnerReceipt, second;
        send helper, eRetireNative;
      } else if (stage == 6 && p.request == second && p.answer == Prior && rowSafe(p.row)) {
        stage = 7;
        send executor, eCloseEpoch;
      } else if (stage == 8 && p.request == first && p.answer == Prior) {
        stage = 9;
        send executor, eCollect, first.key;
      } else if (stage == 10 && p.request == first && p.answer == Fenced) {
        stage = 11;
        send executor, eAdvanceEpoch;
      } else if (stage == 12 && p.request == second && p.answer == Fenced) {
        stage = 14;
        send owner, ePrepare, request(4, 2, 2);
      } else if (stage == 14 && p.request.key.execution == 4 && p.answer == Prior && p.row.phase == Running) {
        stage = 15;
        send helper, eFinishNative;
      } else if (stage == 15 && p.request.key.execution == 4 && p.answer == Prior && p.row.phase == Terminal) {
        assert p.row.outcome == Succeeded, "new epoch execution did not succeed";
        stage = 16;
        send owner, eOwnerReceipt, p.request;
        send helper, eRetireNative;
      } else if (stage == 16 && p.request.key.execution == 4 && p.answer == Prior && rowSafe(p.row)) {
        announce mWitness, Success;
        announce mScenarioEnd;
        goto Finished;
      }
    }
    on eControlDone do {
      if (stage == 17) { stage = 2; send helper, eFinishNative; }
      else if (stage == 7) { stage = 8; send owner, eRetry, first; }
      else if (stage == 9) { stage = 13; send executor, eCrash; }
      else if (stage == 13) { stage = 10; send owner, eRetry, first; }
      else if (stage == 11) { stage = 12; send owner, eRetry, second; }
    }
  }
  state Finished { ignore eView, eControlDone; }
}

// The intent/start crash gap retains an outstanding row. Reconciliation is
// possible after closure, but row GC and epoch advance are both blocked.
machine UncertainScenario {
  var owner: machine;
  var executor: machine;
  var helper: machine;
  var stage: int;
  var first: tRequest;
  start state Init {
    entry {
      announce mScenarioBegin;
      executor = new Executor((driver = this, mode = CrashBeforeStart));
      helper = new Helper();
      owner = new Owner((driver = this, executor = executor, mode = Reliable));
      send executor, eConnect, (owner = owner, helper = helper);
      send helper, eHelperConnect, executor;
      first = request(1, 1, 1);
      send owner, ePrepare, first;
      goto Driving;
    }
  }
  state Driving {
    on eView do (p: tReply) {
      if (stage == 0 && p.answer == Prior && p.row.phase == Intent) {
        stage = 1;
        send owner, eReconnect;
        send owner, eRetry, first;
      } else if (stage == 1 && p.answer == Prior && p.row.phase == Intent) {
        stage = 2;
        send executor, eCloseEpoch;
      } else if (stage == 3 && p.answer == Prior && p.row.phase == Intent) {
        stage = 4;
        send executor, eCollect, first.key;
      } else if (stage == 6 && p.answer == Prior && p.row.phase == Intent) {
        announce mScenarioEnd;
        goto Finished;
      }
    }
    on eControlDone do {
      if (stage == 2) { stage = 3; send owner, eRetry, first; }
      else if (stage == 4) { stage = 5; send executor, eAdvanceEpoch; }
      else if (stage == 5) { stage = 6; send owner, eRetry, first; }
    }
  }
  state Finished { ignore eView, eControlDone; }
}

// Twenty fault actions interleave with actor queues. No liveness is claimed
// for lossy traffic: unanswered intent and unknown custody may remain safe.
machine FaultScenario {
  var owner: machine;
  var executor: machine;
  var helper: machine;
  var remaining: int;
  start state Init {
    entry {
      executor = new Executor((driver = this, mode = Lossy));
      helper = new Helper();
      owner = new Owner((driver = this, executor = executor, mode = Lossy));
      send executor, eConnect, (owner = owner, helper = helper);
      send helper, eHelperConnect, executor;
      send owner, ePrepare, request(1, 1, 1);
      send owner, ePrepare, request(2, 1, 1);
      send owner, ePrepare, request(3, 1, 1);
      send owner, ePrepare, request(4, 2, 2);
      send owner, ePrepare, request(6, 2, 1);
      remaining = 20;
      send this, eTick;
      goto Acting;
    }
  }
  state Acting {
    on eTick do {
      var action: int;
      var r: tRequest;
      if (remaining == 0) { goto Finished; }
      remaining = remaining - 1;
      r = request(choose(3) + 1, 1, 1);
      action = choose(16);
      if (action == 0) { send owner, eRetry, r; }
      else if (action == 1) { send owner, eOwnerReconcile, r; }
      else if (action == 2) { send owner, eOwnerCancel, r; }
      else if (action == 3) { send owner, eOwnerReceipt, r; }
      else if (action == 4) { send owner, eReconnect; }
      else if (action == 5) { send owner, eOwnerCrash; }
      else if (action == 6) { send executor, eCrash; }
      else if (action == 7) { send helper, eFinishNative; }
      else if (action == 8) { send helper, eRetireNative; }
      else if (action == 9) { send helper, eDeliverCancel; }
      else if (action == 10) { send executor, eCloseEpoch; }
      else if (action == 11) { send executor, eCollect, r.key; }
      else if (action == 12) { send executor, eAdvanceEpoch; }
      else if (action == 13) { send helper, eInspectNative; }
      else if (action == 14) { send owner, eRetry, request(4, 2, 2); }
      else { send owner, ePrepare, request(5, 1, 2); }
      send this, eTick;
    }
    ignore eView, eControlDone;
  }
  state Finished { ignore eView, eControlDone; }
}

machine TestLifecycle {
  start state Init { entry { new Lifecycle(Reliable); } }
}
machine TestCrashAfterSend {
  start state Init { entry { new Lifecycle(CrashAfterSend); } }
}

// GC is attempted while exactly one required fact is missing, then retried
// after real delivery of that fact. This catches guard mutations directly.
machine RetentionScenario {
  var owner: machine;
  var executor: machine;
  var helper: machine;
  var stage: int;
  var withheld: tWithheld;
  var first: tRequest;
  start state Init {
    entry (p: tWithheld) {
      announce mScenarioBegin;
      withheld = p;
      executor = new Executor((driver = this, mode = Reliable));
      helper = new Helper();
      owner = new Owner((driver = this, executor = executor, mode = Reliable));
      send executor, eConnect, (owner = owner, helper = helper);
      send helper, eHelperConnect, executor;
      first = request(1, 1, 1);
      send owner, ePrepare, first;
      goto Driving;
    }
  }
  state Driving {
    on eView do (p: tReply) {
      if (stage == 0 && p.answer == Prior && p.row.phase == Running) {
        stage = 1;
        send helper, eFinishNative;
      } else if (stage == 1 && p.answer == Prior && p.row.phase == Terminal) {
        stage = 2;
        if (withheld == ReceiptPending) { send helper, eRetireNative; }
        else { send owner, eOwnerReceipt, first; }
      } else if (stage == 2 && p.answer == Prior && p.row.phase == Terminal &&
                 (p.row.retired || p.row.receipt)) {
        stage = 3;
        send executor, eCloseEpoch;
      } else if (stage == 5 && p.answer == Prior) {
        assert p.row.phase == Terminal, "GC lost retained terminal outcome";
        stage = 6;
        if (withheld == ReceiptPending) { send owner, eOwnerReceipt, first; }
        else { send helper, eRetireNative; }
      } else if (stage == 6 && p.answer == Prior && rowSafe(p.row)) {
        stage = 7;
        send executor, eCollect, first.key;
      }
    }
    on eControlDone do {
      if (stage == 3) { stage = 4; send executor, eCollect, first.key; }
      else if (stage == 4) { stage = 5; send owner, eRetry, first; }
      else if (stage == 7) { announce mScenarioEnd; goto Finished; }
    }
  }
  state Finished { ignore eView, eControlDone; }
}
machine TestReceiptPending {
  start state Init { entry { new RetentionScenario(ReceiptPending); } }
}
machine TestRetirementPending {
  start state Init { entry { new RetentionScenario(RetirementPending); } }
}
