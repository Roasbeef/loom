// The parent's orchestrator (`remote_spawner` and the drainer that resends).
//
// The stub is durable: the owner asks for the spawn, resends it each time the
// drainer pokes until it is answered started or refused, then asks to join each
// time until the child's commits come back. A request to ask again, an unanswered
// message and a lost connection all leave the stage where it was, so the next poke
// asks again. A finished child's commits are made into one ref, once, and only when
// the bundle that arrived is the one its description names.
machine Owner {
  var w1: machine;
  var chaos: machine;
  var stage: int;
  var asked: bool;
  var refApplied: bool;
  var quiet: bool;

  start state Serving {
    entry (wire: machine) {
      w1 = wire;
    }

    on eKnowChaos do (c: machine) {
      chaos = c;
    }

    on ePoke do {
      if (stage == 0) {
        if (!asked) {
          asked = true;
          announce eSpawnAsked;
        }
        send w1, eL2R, (kind = K_SPAWN, pass = 0, a = 1, b = 0, c = 0);
      } else if (stage == 1) {
        send w1, eL2R, (kind = K_JOIN, pass = 0, a = 0, b = 0, c = 0);
      }
    }

    on eInL do (m: tMsg) {
      reply(m);
    }

    on eCrashOwner do {
    }

    // The faults are spent, so the drainer asks again on every answer that is
    // not the last one, which keeps one request in flight and spins on nothing.
    on eQuiet do {
      quiet = true;
      send this, ePoke;
    }

    ignore eLinkLost;
  }

  fun reply(m: tMsg) {
    handle(m);
    if (quiet && stage != 2) {
      send this, ePoke;
    }
  }

  fun handle(m: tMsg) {
    if (m.kind == R_STARTED) {
      if (stage == 0) {
        stage = 1;
        announce eOutcomeSpawned;
      }
    } else if (m.kind == R_REFUSED) {
      if (stage == 0) {
        stage = 2;
        announce eOutcomeRefused;
        send chaos, eOwnerDone;
      }
    } else if (m.kind == R_GONE) {
      if (stage == 1) {
        stage = 2;
        announce eJoinLost;
        send chaos, eOwnerDone;
      }
    } else if (m.kind == R_FINISHED) {
      if (stage == 1) {
        if (m.b == m.c) {
          stage = 2;
          if (!refApplied) {
            refApplied = true;
            announce eRef, (tip = m.a, arrived = m.b, desc = m.c);
          }
          send chaos, eOwnerDone;
        }
      }
    }
  }
}
