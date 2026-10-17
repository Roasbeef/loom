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
machine Laptop {
  var wire: machine;
  var port: machine;
  var stubs: map[tSite, tStub];
  var calls: map[tSite, machine];

  start state Up {
    entry (p: (wire: machine, port: machine)) {
      wire = p.wire;
      port = p.port;
    }

    on eBegin do (s: tPlanSite) {
      stubs[s.site] = (st = ST_REQUESTED, child = 0, run = s.run, owner = s.owner);
      announce eStubRequested, s.site;
      calls[s.site] = new SpawnCall((wire = wire, port = port, laptop = this, site = s));
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
      }
    }

    on eDrain do {
      pass();
    }

    on eAbort do {
      abortCalls();
    }
  }

  fun spawned(site: tSite, child: tChild) {
    announce eStubSpawnedAs, (site = site, child = child);
    if (stubs[site].st == ST_REQUESTED || stubs[site].st == ST_REFUSED) {
      stubs[site].st = ST_SPAWNED;
      stubs[site].child = child;
      announce eStubDone, site;
    }
  }

  fun refused(site: tSite) {
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

  // One drainer pass.
  fun pass() {
    var s: tSite;
    var ss: seq[tSite];
    ss = keys(stubs);
    foreach (s in ss) {
      if (stubs[s].st == ST_REQUESTED) {
        send wire, eSend, (sender = this, msg = (kind = K_SPAWN, src = this, dest = port, site = s, child = 0, st = CS_RUNNING, run = stubs[s].run, owner = stubs[s].owner));
      } else if (stubs[s].st == ST_SPAWNED) {
        send wire, eSend, (sender = this, msg = (kind = K_JOIN, src = this, dest = port, site = s, child = stubs[s].child, st = CS_RUNNING, run = stubs[s].run, owner = stubs[s].owner));
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
