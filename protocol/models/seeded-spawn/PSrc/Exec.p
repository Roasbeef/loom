// The executor that holds the child's workspace (the scope of a session on a
// `workspace` in worktree mode).
//
// Durable: the tree's tip, which survives a restart because the tree is a
// directory; the bundle store; the count of attaches, so a token is never reused.
// A restart bumps the incarnation and loses the attach, so every request that
// carries the old fence is refused as stale, and the orchestrator attaches anew.
//
// The apply is fenced by the incarnation and the token and is idempotent: the
// executor records the tip it applied last, and a request for that tip is answered
// and touches nothing (`state_apply`). A request for another tip is checked out in
// the tree whatever the tree holds, because the executor cannot tell a tree the
// child has worked in from a fresh one beyond a few checks. Only one checkout runs
// at a time for a scope: a request that arrives while one is running joins it.
machine Exec {
  var w2: machine;
  var plan: tPlan;
  var tip: int;
  var stored: bool;
  var childRuns: bool;
  var epoch: int;
  var tokens: int;
  var liveToken: int;
  var noRoomLeft: int;
  var applying: bool;
  var waiters: seq[int];
  var applyTip: int;
  var lastApplied: int;
  var partialLeft: int;

  start state Serving {
    entry (p: (w2: machine, plan: tPlan)) {
      w2 = p.w2;
      plan = p.plan;
      noRoomLeft = p.plan.noRoom;

      // A workspace whose base is ahead of the parent's commit starts the scope's
      // tree on that base, which is not the parent's.
      if (p.plan.behind) {
        tip = 9;
      }
      partialLeft = p.plan.partial;
    }

    on eInR do (m: tMsg) {
      serve(m);
    }

    // The child commits soon after its first turn begins.
    on eChildStopped do {
      childRuns = false;
    }

    on eChildStarted do {
      childRuns = true;
      send this, eChildWork;
    }

    // The child works in the tree only once its first turn has begun.
    on eChildWork do {
      if (childRuns && tip == 1) {
        tip = 2;
      }
    }

    // The checkout ends and answers every request that waited for it.
    // A checkout takes some time, so its end is a step that the scheduler may put
    // off, and a second request can arrive while it runs.
    on eApplyDone do (e: int) {
      if (e == epoch && applying) {
        if (choose(3) == 0) {
          finishApply();
        } else {
          send this, eApplyDone, epoch;
        }
      }
    }

    on eCrashExec do {
      epoch = epoch + 1;
      liveToken = 0;

      // The run of a checkout dies with the executor.
      if (applying) {
        announce eApplyEnded;
      }
      applying = false;
      waiters = default(seq[int]);
    }

    ignore eLinkLost;
  }

  fun answer(m: tMsg, k: tKind, a: int, b: int, c: int) {
    send w2, eR2L, (kind = k, pass = m.pass, a = a, b = b, c = c);
  }

  // Whether a request's fence is the live attach's.
  fun fenced(m: tMsg): bool {
    return liveToken != 0 && m.b == epoch && m.c == liveToken;
  }

  // The checkout ends: the tree takes the tip, and every request that waited is
  // answered with it.
  fun finishApply() {
    var i: int;
    announce eApplyEnded;

    // A tip the executor applied before is answered and the tree is not touched,
    // so a request that arrives late, after the child began to work, changes
    // nothing.
    if (lastApplied == applyTip) {
      announce eApplyRepeated;
    } else {
      announce eApplied, (before = tip, after = applyTip);

      // The first apply of a state moves the tree onto it, whatever the tree held.
      if (lastApplied == 0) {
        announce eSeedEffective;
      }
      announce eTreeSeeded, applyTip;
      tip = applyTip;
      lastApplied = applyTip;
    }
    i = 0;
    while (i < sizeof(waiters)) {
      send w2, eR2L, (kind = Y_APPLIED, pass = waiters[i], a = applyTip, b = 0, c = 0);
      i = i + 1;
    }
    waiters = default(seq[int]);
    applying = false;
  }

  fun serve(m: tMsg) {
    var arrived: int;
    var mode: int;
    if (m.kind == X_ATTACH) {
      tokens = tokens + 1;
      liveToken = tokens;
      mode = 0;
      if (plan.shared) {
        mode = 1;
      }
      answer(m, Y_ATTACHED, mode, epoch, liveToken);
    } else if (m.kind == X_SEND) {
      if (noRoomLeft > 0 && choose(2) == 0) {
        noRoomLeft = noRoomLeft - 1;
        answer(m, Y_SENT, 2, 0, 0);
      } else if (plan.badState) {
        answer(m, Y_SENT, 3, 0, 0);
      } else {
        stored = true;
        answer(m, Y_SENT, 1, 0, 0);
      }
    } else if (m.kind == X_APPLY) {
      if (!fenced(m)) {
        answer(m, Y_STALE, 0, 0, 0);
      } else if (!stored || plan.refuseApply) {
        answer(m, Y_REFUSED, 0, 0, 0);
      } else if (applying) {
        // A request for the state that is being applied joins that run and gets its
        // answer, because a second checkout over the first one's tree would fail on
        // what the first made.
        waiters += (sizeof(waiters), m.pass);
        announce eApplyJoined;
      } else {
        applying = true;
        applyTip = m.a;
        waiters += (sizeof(waiters), m.pass);
        announce eApplyStarted;
        send this, eApplyDone, epoch;
      }
    } else if (m.kind == X_CAPTURE) {
      if (!fenced(m)) {
        answer(m, Y_STALE, 0, 0, 0);
      } else {
        arrived = tip;
        if (partialLeft > 0 && tip > 0 && choose(2) == 0) {
          partialLeft = partialLeft - 1;
          arrived = tip - 1;
        }
        if (epoch > 0) {
          announce eCapturedAfterRestart;
        }
        answer(m, Y_CAPTURED, tip, arrived, tip);
      }
    }
  }
}
