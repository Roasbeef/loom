// The executor that holds the child's workspace (the scope of a session on a
// `workspace` in worktree mode).
//
// Durable: the tree's tip, which survives a restart because the tree is a
// directory; the bundle store; the count of attaches, so a token is never reused.
// A restart bumps the incarnation and loses the attach, so every request that
// carries the old fence is refused as stale, and the orchestrator attaches anew.
//
// The apply is fenced by the incarnation and the token and is idempotent: a tip
// the tree already has is answered and touches nothing. It takes any tip over a
// tree at another one, because the executor cannot tell a tree the child has worked
// in from a fresh one beyond a few checks. What keeps the child's work is the
// orchestrator, which asks the session whether it has begun before it sends the
// request, and `NoOlderOverNewer` is the rule that holds the orchestrator to it.
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
  var partialLeft: int;

  start state Serving {
    entry (p: (w2: machine, plan: tPlan)) {
      w2 = p.w2;
      plan = p.plan;
      noRoomLeft = p.plan.noRoom;
      partialLeft = p.plan.partial;
    }

    on eInR do (m: tMsg) {
      serve(m);
    }

    // The child commits soon after its first turn begins.
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

    on eCrashExec do {
      epoch = epoch + 1;
      liveToken = 0;
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
      } else {
        announce eApplied, (before = tip, after = m.a);
        if (tip == m.a) {
          announce eApplyRepeated;
        }
        if (tip == 0) {
          announce eSeedEffective;
          announce eTreeSeeded;
        }
        tip = m.a;
        answer(m, Y_APPLIED, tip, 0, 0);
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
