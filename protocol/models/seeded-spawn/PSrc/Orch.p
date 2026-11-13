// The receiving orchestrator: `spawn_seed.land`, the delegate session of the
// child, the Agency's spawn and the join.
//
// Durable, as the code keeps them in files and a registry: the verdict
// (`<name>.refused`), the child's session record, the lineage cell that says the
// child began, the bundle in the state store, a directory placement's copy, and a
// stored result of the join. Volatile: whether the session is open and resident,
// the claim, the pass in progress, the executor attach (token and incarnation),
// and whether an asker still waits. A restart clears the volatile part and ends the
// child's run, and the claim is taken as stale by the next ask.
//
// An ask for the spawn is answered in the order of `landed`:
//
// 1. a verdict is answered at once;
// 2. a session that is open and resident is asked whether it has begun, and a
//    child that has is the answer, while a record that cannot be read is a reason
//    to ask again and is never taken for a child that has begun;
// 3. a bundle that is not all held is a reason to ask again;
// 4. otherwise a pass runs under the claim: the session is found or made, the
//    scope is attached and its census read, the bundle is sent, the session is
//    asked again whether it has begun, and the apply is sent;
// 5. the Agency's spawn is the child's first turn, made once the pass is done and
//    only if the asker still waits.
//
// A failure is either transient, which keeps no verdict and leaves the session, or
// a deterministic refusal, which keeps the verdict and ends the session in a step
// of its own after the verdict is written. A refusal by the census keeps no verdict
// and ends the session at once.
machine Orch {
  var w1: machine;
  var w2: machine;
  var exec: machine;
  var plan: tPlan;

  // Durable.
  var verdict: bool;
  var session: bool;
  var begun: bool;
  var held: bool;
  var localTip: int;
  var finished: bool;
  var resultStored: bool;
  var resultTip: int;
  var resultArrived: int;
  var resultDesc: int;

  // Volatile.
  var resident: bool;
  var claim: bool;
  var joining: bool;
  var phase: tPhase;
  var pass: int;
  var inc: int;
  var token: int;
  var attached: bool;
  var askerWaiting: bool;
  var confirmed: bool;
  var epoch: int;
  var unreadableLeft: int;
  var storeFullLeft: int;

  start state Serving {
    entry (p: (w1: machine, w2: machine, exec: machine, plan: tPlan)) {
      w1 = p.w1;
      w2 = p.w2;
      exec = p.exec;
      plan = p.plan;
      held = !p.plan.holdLate;
      unreadableLeft = p.plan.unreadable;
      storeFullLeft = p.plan.storeFull;
    }

    on eInR do (m: tMsg) {
      if (m.kind == K_SPAWN) {
        handleSpawn();
      } else if (m.kind == K_JOIN) {
        handleJoin();
      }
    }

    on eInL do (m: tMsg) {
      handleExec(m);
    }

    on eLinkLost do (w: int) {
      if (w == 1) {
        askerWaiting = false;
      } else if (phase == PH_APPLY) {
        // The surface repairs the connection and sends the apply again, because an
        // apply that already landed answers its tip and changes nothing. The
        // first checkout may still be running when the second request arrives.
        toExec(X_APPLY, 1, inc, token);
      } else {
        abandon();
      }
    }

    on eGiveUp do {
      askerWaiting = false;
    }

    on eBundleArrives do {
      held = true;
    }

    on eChildWork do {
      if (plan.place == PL_DIR && begun && !finished && localTip == 1) {
        localTip = 2;
      }
    }

    on eCrashOrch do {
      crash();
    }

    on eSpawnDue do (e: int) {
      if (e == epoch && askerWaiting) {
        spawnChild();
      }
    }

    // The end of a refused child's session, and then the answer to the asker that
    // is still waiting. `placing` ends the session before it returns the refusal,
    // so the asker hears nothing from a daemon that stopped before the end.
    on eReleaseDue do (e: int) {
      if (e == epoch) {
        releaseSession();
        if (askerWaiting) {
          askerWaiting = false;
          toOwner(R_REFUSED, 0, 0, 0);
        }
      }
    }

    // The child runs for some time, so its end is a step that the scheduler may
    // put off, and a join can arrive while it runs.
    on eChildFinish do (e: int) {
      if (e == epoch && begun && !finished) {
        if (choose(3) == 0) {
          endChild();
        } else {
          send this, eChildFinish, epoch;
        }
      }
    }

    on eRunEnded do {
      runEnd();
    }
  }

  fun toOwner(k: tKind, a: int, b: int, c: int) {
    send w1, eR2L, (kind = k, pass = pass, a = a, b = b, c = c);
  }

  fun toExec(k: tKind, a: int, b: int, c: int) {
    send w2, eL2R, (kind = k, pass = pass, a = a, b = b, c = c);
  }

  // Whether the child's session has begun, as its record says. A read that fails
  // is `FR_UNREADABLE`.
  fun readFresh(): tFresh {
    if (unreadableLeft > 0 && choose(2) == 0) {
      unreadableLeft = unreadableLeft - 1;
      return FR_UNREADABLE;
    }
    if (begun) {
      return FR_BEGUN;
    }
    return FR_FRESH;
  }

  // A restart: the volatile part is gone, the run of a child that began has ended,
  // and what the next ask finds is what was durable.
  fun crash() {
    if (confirmed && !begun) {
      announce eCrashBetween;
    }
    epoch = epoch + 1;
    resident = false;
    claim = false;
    joining = false;
    phase = PH_IDLE;
    attached = false;
    askerWaiting = false;
    confirmed = false;

    // The daemon deletes `seed-staging` at start, where the claims and the
    // refusals it kept are, so a restart forgets both.
    verdict = false;
    if (begun && !finished) {
      endChild();
    }
  }

  // The child's run ends, and it commits nothing after that.
  fun endChild() {
    finished = true;
    announce eChildEnded;
    send exec, eChildStopped;
  }

  // The run that asked for the child ended. The children that run in sessions of
  // their own are stopped first and whatever becomes of the pair's session, which
  // cannot be made when seeded children fill the cap. Their sessions are kept, so
  // a join can still bring the commits back.
  fun runEnd() {
    // The children first.
    if (begun && !finished) {
      endChild();
      announce eRunEndStopped;
    }

    // The pair's session is the next step, and a spawner at its cap refuses it.
    announce eRunEndHandled, (begun && !finished);
  }

  // The link to the executor broke while a request was out: the work ends with a
  // request to ask again.
  fun abandon() {
    if (phase != PH_IDLE) {
      if (joining) {
        joining = false;
        phase = PH_IDLE;
      } else {
        transient(W_TIMEOUT);
      }
    }
  }

  fun handleSpawn() {
    var fr: tFresh;
    if (verdict) {
      // An ask that arrives between the verdict and the end of the session ends
      // it, and the owner it answers asks no more.
      releaseSession();
      toOwner(R_REFUSED, 0, 0, 0);
      return;
    }
    if (session && resident) {
      fr = readFresh();
      if (fr == FR_BEGUN) {
        announce eGate, begun;
        toOwner(R_STARTED, 0, 0, 0);
        return;
      }
      if (fr == FR_UNREADABLE) {
        toOwner(R_ASKAGAIN, 0, 0, 0);
        return;
      }
    }
    if (!held) {
      toOwner(R_ASKAGAIN, 0, 0, 0);
      return;
    }
    startPass();
  }

  fun startPass() {
    if (claim || joining) {
      toOwner(R_ASKAGAIN, 0, 0, 0);
      return;
    }
    claim = true;
    pass = pass + 1;
    askerWaiting = true;
    if (plan.place == PL_DIR) {
      copyIn();
      return;
    }
    if (!session) {
      session = true;
      announce eSessionMade;
    }
    resident = true;
    if (!attached) {
      phase = PH_ATTACH;
      toExec(X_ATTACH, 0, 0, 0);
    } else {
      sendBundle();
    }
  }

  // A directory placement: the copy is made under the claim and kept.
  fun copyIn() {
    if (plan.badState) {
      refuse(W_BADSTATE);
      return;
    }
    if (localTip == 0) {
      localTip = 1;
      announce eSeedEffective;
      announce eTreeSeeded;
    }
    finishPass();
  }

  fun sendBundle() {
    phase = PH_SEND;
    toExec(X_SEND, 0, 0, 0);
  }

  fun handleExec(m: tMsg) {
    if (m.pass != pass) {
      return;
    }
    if (m.kind == Y_ATTACHED) {
      if (phase == PH_ATTACH) {
        inc = m.b;
        token = m.c;
        attached = true;
        if (m.a == 1) {
          refuseCensus();
        } else {
          sendBundle();
        }
      } else if (phase == PH_JATTACH) {
        inc = m.b;
        token = m.c;
        attached = true;
        phase = PH_CAPTURE;
        toExec(X_CAPTURE, 0, inc, token);
      }
    } else if (m.kind == Y_SENT && phase == PH_SEND) {
      if (m.a == 1) {
        afterSend();
      } else if (m.a == 2) {
        transient(W_NOROOM);
      } else {
        refuse(W_BADSTATE);
      }
    } else if (m.kind == Y_APPLIED && phase == PH_APPLY) {
      confirmed = true;
      finishPass();
    } else if (m.kind == Y_STALE) {
      attached = false;
      if (phase == PH_APPLY) {
        transient(W_STALE);
      } else if (phase == PH_CAPTURE) {
        joining = false;
        phase = PH_IDLE;
        toOwner(R_PENDING, 0, 0, 0);
      }
    } else if (m.kind == Y_REFUSED && phase == PH_APPLY) {
      refuse(W_WORKSPACE);
    } else if (m.kind == Y_CAPTURED && phase == PH_CAPTURE) {
      joining = false;
      phase = PH_IDLE;
      if (m.b != m.c) {
        toOwner(R_PENDING, 0, 0, 0);
      } else if (storeIsFull()) {
        // This node's store has no room for the commits, which passes: the join
        // is asked again and the session and the commits are kept.
        announce eStoreFull;
        toOwner(R_PENDING, 0, 0, 0);
      } else {
        storeResult(m.a, m.b, m.c);
      }
    }
  }

  // The bundle is on the executor. The session is asked once more whether it has
  // begun, at the moment before the request, because the executor cannot tell.
  fun afterSend() {
    var fr: tFresh;
    fr = readFresh();
    if (fr == FR_BEGUN) {
      announce eGate, begun;
      finishPass();
      return;
    }
    if (fr == FR_UNREADABLE) {
      transient(W_UNREADABLE);
      return;
    }
    phase = PH_APPLY;
    toExec(X_APPLY, 1, inc, token);
  }

  // The pass is done and the workspace is in place, or the child had begun. The
  // Agency's spawn is a step of its own, which a restart can come between.
  fun finishPass() {
    claim = false;
    phase = PH_IDLE;
    send this, eSpawnDue, epoch;
  }

  // The Agency's spawn is the child's first turn. A child that began is answered
  // as it was and starts nothing.
  fun spawnChild() {
    if (!begun) {
      begun = true;
      announce eFirstTurn;

      // The child's process runs on the executor's tree, so it learns directly
      // that it began and does not cross the link.
      send exec, eChildStarted;
      send this, eChildFinish, epoch;
    }
    askerWaiting = false;
    toOwner(R_STARTED, 0, 0, 0);
  }

  // A failure that asking again can cure: nothing is kept, the claim is let go and
  // the session stays.
  fun transient(why: tWhy) {
    announce eTransient, why;
    claim = false;
    phase = PH_IDLE;
    if (askerWaiting) {
      askerWaiting = false;
      toOwner(R_ASKAGAIN, 0, 0, 0);
    }
  }

  // A refusal the same inputs get again: the verdict is kept before the claim is
  // let go, and the session is ended and the asker answered in a step of their
  // own, which a restart can come before.
  fun refuse(why: tWhy) {
    verdict = true;
    announce eVerdict, why;
    claim = false;
    phase = PH_IDLE;
    send this, eReleaseDue, epoch;
  }

  // The census says the workspace takes no state. No verdict is kept, and the
  // session just made is ended before the answer.
  fun refuseCensus() {
    claim = false;
    phase = PH_IDLE;
    releaseSession();
    if (askerWaiting) {
      askerWaiting = false;
      toOwner(R_REFUSED, 0, 0, 0);
    }
  }

  fun releaseSession() {
    if (session) {
      session = false;
      resident = false;
      attached = false;
      announce eSessionReleased;
      toExec(X_RELEASE, 0, 0, 0);
    }
  }

  fun handleJoin() {
    if (!begun) {
      toOwner(R_PENDING, 0, 0, 0);
      return;
    }
    if (resultStored) {
      announce eRepeated;
      releaseSession();
      toOwner(R_FINISHED, resultTip, resultArrived, resultDesc);
      return;
    }
    if (plan.place == PL_EXEC && !session) {
      announce eGone, resultStored;
      toOwner(R_GONE, 0, 0, 0);
      return;
    }
    if (!finished || claim || joining) {
      toOwner(R_PENDING, 0, 0, 0);
      return;
    }
    if (plan.place == PL_DIR) {
      announce eSettled, localTip;
      toOwner(R_FINISHED, localTip, localTip, localTip);
      return;
    }
    joining = true;
    pass = pass + 1;
    if (attached) {
      phase = PH_CAPTURE;
      toExec(X_CAPTURE, 0, inc, token);
    } else {
      phase = PH_JATTACH;
      toExec(X_ATTACH, 0, 0, 0);
    }
  }

  // Whether this node's store has no room for the captured commits this time.
  fun storeIsFull(): bool {
    if (storeFullLeft > 0 && choose(2) == 0) {
      storeFullLeft = storeFullLeft - 1;
      return true;
    }
    return false;
  }

  // The join answers with the child's commits. The settled answer is kept before
  // the child's session is ended, so a join asked again afterwards is answered the
  // same, and the session is ended after it.
  fun storeResult(tip: int, arrived: int, desc: int) {
    announce eSettleBegan;
    resultStored = true;
    resultTip = tip;
    resultArrived = arrived;
    resultDesc = desc;
    announce eKept;
    announce eSettled, tip;
    releaseSession();
    toOwner(R_FINISHED, tip, arrived, desc);
  }
}
