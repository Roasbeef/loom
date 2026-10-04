// One native slot is reused by multiple logical executions. Cancellation
// can wait in transport until reuse, so helper identity alone is insufficient.
machine Helper {
  var executor: machine;
  var active: tNative;
  var busy: bool;
  var terminal: bool;
  var outcome: tOutcome;
  var pending: seq[tNative];

  start state Init {
    entry { goto Ready; }
  }

  state Ready {
    on eHelperConnect do (p: machine) { executor = p; }
    on eStartNative do (p: tNative) {
      // A saturated native slot retains uncertainty rather than queuing an
      // unbounded set of starts. Retry cannot regenerate launch permission.
      if (!busy) {
        busy = true;
        terminal = false;
        outcome = NoOutcome;
        active = p;
        announce mStart, p;
        send executor, eStartedNative, p;
      }
    }
    on eFinishNative do {
      if (busy && !terminal) {
        terminal = true;
        outcome = Succeeded;
        send executor, eTerminalNative, (native = active, outcome = outcome);
      }
    }
    on eRetireNative do {
      // Retirement may follow terminal by arbitrarily many scheduling
      // steps. This is the abstract descendant-retirement witness.
      if (busy && terminal) {
        busy = false;
        send executor, eRetiredNative, active;
      }
    }
    on eCancelNative do (p: tNative) {
      if (sizeof(pending) < 2) { pending += (sizeof(pending), p); }
    }
    on eDeliverCancel do {
      var asked: tNative;
      if (sizeof(pending) > 0) {
        asked = pending[0];
        pending -= (0);
        if (busy && asked != active) { announce mWitness, Reuse; }
        if (busy && asked == active) {
          announce mCancelEffect, (asked = asked, active = active);
          terminal = true;
          outcome = Cancelled;
          send executor, eTerminalNative, (native = active, outcome = outcome);
        }
      }
    }
    on eInspectNative do {
      // Recovery inventory can restore evidence without starting anything.
      if (busy) {
        send executor, eStartedNative, active;
        if (terminal) { send executor, eTerminalNative, (native = active, outcome = outcome); }
      }
    }
  }
}
