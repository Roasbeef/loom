// The parent session's store, its Agency and its remote drainer
// (`remote_child.gleam`, `remote_drain.gleam`, `agency.gleam`).
//
// `stubs` is the `remote-child/{site digest}` fact: durable, written before any
// message is sent, and the only pending row. `calls` is memory, one SpawnCall
// per call site that the model's effect process has running, and an abort
// kills them all while leaving the stubs.
//
// | The stub is | A drainer pass sends |
// |---|---|
// | `ST_REQUESTED` | `Spawn`, from the stored request |
// | `ST_SPAWNED` | `Join` with a window of zero for the child it names |
// | `ST_SETTLED` or `ST_REFUSED` | nothing |
//
// An answer is written to the stub whoever receives it, the SpawnCall or the
// drainer. A stub that names a child keeps naming it: a second answer that
// names another child is announced, and a spec fails on it. A `Refused` stub is
// kept, and a later `Spawned` moves it to `ST_SPAWNED` (design note, section
// 8.2). A `Joined` answer that reports a terminal state settles the stub; the
// drainer does not store the report.
//
// Mail from a child (`K_MAIL`) is admitted by the child's call site, which is the
// stub's name: the stub is written before the first `Spawn` leaves, so the stub
// exists in every state, `ST_REQUESTED` included, and the mail never needs the
// handle. The laptop answers in this order:
//
// | The laptop holds | It answers |
// |---|---|
// | the parent session closed | `MAIL_NOT_OPEN`, which the remote asks again about |
// | no stub for the child | `MAIL_UNKNOWN` |
// | a receipt for the mail's id | the receipt, and steers nothing |
// | the parent's run open | steers the parent and stores `MAIL_DELIVERED` |
// | the parent's run ended | stores `MAIL_DECLINED`: a finished parent is not woken |
//
// The steer and the receipt are one commit, so a mail steers the parent at most
// once however often the remote resends it.
//
// Deleting the parent session (`eDelete`) writes one release row for the remote
// when some stub is not refused, and then removes the stubs and kills the effect
// processes with the session. The row is the catalogue's
// `catalogue_remote_releases`, written before the session goes and kept until
// the remote answers. A drainer pass sends `Release` for it. The pass watches the
// connection while it waits, and a break tells it the call was unreachable,
// which is not an answer: the row stays and the next pass sends again. Only
// `Released` settles the row. A message that arrives for a stub the deletion
// removed is dropped.
//
// The same machine plays the box's delegate session as a spawner (phase 4, the
// relay). Its `ports` are the third orchestrators, and a stub names the one it
// was placed on. Its release rows are written when the box's Port deletes the
// released session, after its slot has drained, and tells it so (`eCascade`):
// one row for each third orchestrator that a stub that is not refused names,
// which the registry reads from the closed file in the code. In the same step
// the stubs and the effect processes go with the session, and the relay rings
// its own drainer, as the registry rings the daemon's release drainer. Until
// then the relay is a live session and goes on resending what it owes. The rows
// are a set of orchestrators, one row each, as the catalogue keeps them.
//
// `eOweReleases` writes the rows and leaves the session as it is. Nothing sends
// it in the model as built; it is what a release that wrote the rows before the
// slot drained would do, and `mutate.py` sends it to show that is caught.
machine Laptop {
  var wire: machine;
  var ports: seq[machine];
  var stubs: map[tSite, tStub];
  var calls: map[tSite, machine];
  var releaseOwed: set[machine];
  var watchingRelease: bool;
  var open: bool;
  var runOpen: bool;
  var receipts: map[int, tMailCode];

  start state Up {
    entry (p: (wire: machine, ports: seq[machine])) {
      wire = p.wire;
      ports = p.ports;
      open = true;
      runOpen = true;
    }

    on eBegin do (s: tPlanSite) {
      var dest: machine;
      var spare: machine;
      dest = ports[s.target];
      spare = ports[(s.target + 1) % sizeof(ports)];
      stubs[s.site] = (st = ST_REQUESTED, child = 0, run = s.run, owner = s.owner, dest = dest);
      announce eStubRequested, s.site;
      calls[s.site] = new SpawnCall((wire = wire, port = dest, spare = spare, laptop = this, site = s));
    }

    on eCascade do {
      var owed: set[machine];
      owed = deleteSession();
      announce eCascadeWritten, owed;
      if (sizeof(owed) > 0) {
        send this, eDrain;
      }
    }

    on eOweReleases do {
      var owed: set[machine];
      owed = oweReleases();
      if (sizeof(owed) > 0) {
        send this, eDrain;
      }
    }

    on eStubAnswer do (a: (site: tSite, child: tChild)) {
      spawned(a.site, a.child);
    }

    on eStubRefusal do (site: tSite) {
      refused(site);
    }

    on eNet do (m: tMsg) {
      if (m.kind == K_SPAWNED) {
        spawned(m.site, m.child);
      } else if (m.kind == K_REFUSED) {
        refused(m.site);
      } else if (m.kind == K_JOINED) {
        joined(m);
      } else if (m.kind == K_RELEASED) {
        released(m.src);
      } else if (m.kind == K_MAIL) {
        mail(m);
      }
    }

    on eParentClose do {
      open = false;
    }

    on eParentOpen do {
      open = true;
      send ports[0], eMailPass;
    }

    on eParentRunEnds do {
      if (runOpen) {
        runOpen = false;
        announce eRunClosed;
      }
    }

    on eNoConn do {
      // The call was unreachable. The Release may or may not have arrived, so
      // the row stays owed and the next pass sends it again.
      watchingRelease = false;
    }

    on eDrain do {
      pass();
    }

    on eDelete do {
      var owed: set[machine];
      owed = deleteSession();
    }

    on eAbort do {
      abortCalls();
    }
  }

  fun spawned(site: tSite, child: tChild) {
    if (!(site in stubs)) {
      return;
    }
    announce eStubSpawnedAs, (site = site, child = child);
    if (stubs[site].st == ST_REQUESTED || stubs[site].st == ST_REFUSED) {
      stubs[site].st = ST_SPAWNED;
      stubs[site].child = child;
      announce eStubDone, site;
    }
  }

  fun refused(site: tSite) {
    if (!(site in stubs)) {
      return;
    }
    if (stubs[site].st == ST_REQUESTED) {
      stubs[site].st = ST_REFUSED;
      announce eStubDone, site;
    }
  }

  fun joined(m: tMsg) {
    if (m.site in stubs && stubs[m.site].st == ST_SPAWNED) {
      if (m.st != CS_RUNNING) {
        announce eReported, (site = m.site, child = m.child, st = m.st);
        stubs[m.site].st = ST_SETTLED;
      }
    }
  }

  // A child's mail. The answer is the receipt, and a receipt is final.
  fun mail(m: tMsg) {
    if (!open) {
      announce eMailNotOpen;
      reply(m, MAIL_NOT_OPEN);
      return;
    }
    if (!(m.site in stubs)) {
      announce eUnknownAnswered, (site = m.site, hasStub = (m.site in stubs));
      reply(m, MAIL_UNKNOWN);
      return;
    }
    if (m.id in receipts) {
      announce eMailRepeated;
      reply(m, receipts[m.id]);
      return;
    }
    if (stubs[m.site].st == ST_REQUESTED) {
      announce eMailForRequested;
    }
    if (runOpen) {
      receipts[m.id] = MAIL_DELIVERED;
      announce eSteered, m.id;
      reply(m, MAIL_DELIVERED);
    } else {
      receipts[m.id] = MAIL_DECLINED;
      announce eMailDeclined;
      reply(m, MAIL_DECLINED);
    }
  }

  fun reply(m: tMsg, code: tMailCode) {
    send wire, eSend, (sender = this, msg = (kind = K_MAILED, src = this, dest = m.src, site = m.site, child = m.child, st = CS_RUNNING, run = 0, owner = -1, id = m.id, code = code));
  }

  // An orchestrator answered a release. Only an answer settles its row.
  fun released(from: machine) {
    if (from in releaseOwed) {
      releaseOwed -= (from);
      announce eReleaseTold, (who = this, port = from);
    }
    if (watchingRelease && sizeof(releaseOwed) == 0) {
      send wire, eUnwatch, this;
      watchingRelease = false;
    }
  }

  // The parent session is deleted: one release row for each orchestrator that a
  // stub that is not refused names, then the stubs and the effect processes go.
  // A stub that was still owed is not owed any more. Answers the orchestrators
  // that are owed a release now, rows already owed included.
  fun deleteSession(): set[machine] {
    var s: tSite;
    var ss: seq[tSite];
    var owe: set[machine];
    owe = oweReleases();
    ss = keys(stubs);
    foreach (s in ss) {
      if (stubs[s].st == ST_REQUESTED) {
        announce eStubDone, s;
      }
    }
    abortCalls();
    stubs = default(map[tSite, tStub]);
    return owe;
  }

  // One release row for each orchestrator that a stub that is not refused
  // names, kept once each. Answers the orchestrators owed now, rows already
  // owed included.
  fun oweReleases(): set[machine] {
    var s: tSite;
    var ss: seq[tSite];
    var owe: set[machine];
    var p: machine;
    ss = keys(stubs);
    foreach (s in ss) {
      if (stubs[s].st != ST_REFUSED) {
        owe += (stubs[s].dest);
      }
    }
    foreach (p in owe) {
      if (!(p in releaseOwed)) {
        releaseOwed += (p);
        announce eReleaseWritten, (who = this, port = p);
      }
    }
    return owe;
  }

  // One drainer pass. Every stub's messages go to the orchestrator the stub
  // names, and never to another.
  fun pass() {
    var s: tSite;
    var ss: seq[tSite];
    var p: machine;
    if (sizeof(releaseOwed) > 0) {
      send wire, eWatch, this;
      watchingRelease = true;
      foreach (p in releaseOwed) {
        send wire, eSend, (sender = this, msg = (kind = K_RELEASE, src = this, dest = p, site = 0, child = 0, st = CS_RUNNING, run = 0, owner = -1, id = 0, code = MAIL_DELIVERED));
      }
    }
    ss = keys(stubs);
    foreach (s in ss) {
      if (stubs[s].st == ST_REQUESTED) {
        send wire, eSend, (sender = this, msg = (kind = K_SPAWN, src = this, dest = stubs[s].dest, site = s, child = 0, st = CS_RUNNING, run = stubs[s].run, owner = stubs[s].owner, id = 0, code = MAIL_DELIVERED));
      } else if (stubs[s].st == ST_SPAWNED) {
        send wire, eSend, (sender = this, msg = (kind = K_JOIN, src = this, dest = stubs[s].dest, site = s, child = stubs[s].child, st = CS_RUNNING, run = stubs[s].run, owner = stubs[s].owner, id = 0, code = MAIL_DELIVERED));
      }
    }
  }

  // The parent run is aborted: its effect processes die, its stubs stay.
  fun abortCalls() {
    var s: tSite;
    var ss: seq[tSite];
    ss = keys(calls);
    foreach (s in ss) {
      send calls[s], halt;
    }
    calls = default(map[tSite, machine]);
  }
}
