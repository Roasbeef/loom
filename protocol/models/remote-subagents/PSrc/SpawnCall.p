// One effect process: the `agent_spawn` call for one call site
// (`remote_spawn.gleam`).
//
// The stub is already written when this process starts, so killing it loses
// nothing but a message that may still be in flight. It sends `Spawn` and waits.
// When the connection breaks it sends the same `Spawn` again, as `remote_spawn`
// resends on `Unreachable`. The answer is handed to the Laptop, which writes it
// to the stub, and the process ends. The Laptop kills it when the parent run is
// aborted (`eAbort`).
machine SpawnCall {
  var wire: machine;
  var port: machine;
  var laptop: machine;
  var site: tSite;
  var run: int;
  var owner: int;

  start state Begin {
    entry (p: (wire: machine, port: machine, laptop: machine, site: tPlanSite)) {
      wire = p.wire;
      port = p.port;
      laptop = p.laptop;
      site = p.site.site;
      run = p.site.run;
      owner = p.site.owner;
      send wire, eWatch, this;
      sendSpawn();
      goto Waiting;
    }
  }

  state Waiting {
    on eNet do (m: tMsg) {
      if (m.site != site) {
        return;
      }
      if (m.kind == K_SPAWNED) {
        send wire, eUnwatch, this;
        send laptop, eStubAnswer, (site = site, child = m.child);
        raise halt;
      } else if (m.kind == K_REFUSED) {
        send wire, eUnwatch, this;
        send laptop, eStubRefusal, site;
        raise halt;
      }
    }

    on eNoConn do {
      send wire, eWatch, this;
      sendSpawn();
    }
  }

  fun sendSpawn() {
    send wire, eSend, (sender = this, msg = (kind = K_SPAWN, src = this, dest = port, site = site, child = 0, st = CS_RUNNING, run = run, owner = owner, id = 0, code = MAIL_DELIVERED));
  }
}
