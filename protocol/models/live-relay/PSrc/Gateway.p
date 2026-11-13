// The gateway and its hub, as the feed host sees them.
//
// The gateway writes replies and pushes to the feed host's sink from one
// process, so the order in which it sends `eSink` is the order a local page
// would receive them. It accepts the lane frames the feed host forwards, and
// answers each with a reply frame, sometimes after a push.
//
// The hub has two doors. The relayed door is the one the feed host calls for an
// `approve` or `deny` from the page (`gateway.decide_relayed`). The local door
// is the box owner's own approve. Nothing the feed host does may reach the local
// door, and the model records which door every decision used and who called it.
machine Gateway {
  var host: machine;
  var nextGid: int;
  var attached: int;

  start state Running {
    entry {
      nextGid = 1;
      attached = 1;
    }

    on eGwWire do (h: machine) {
      host = h;
    }

    // A push from the session. It is written only while the feed is attached.
    on eEmit do (size: int) {
      if (attached == 1) {
        write(size, FK_PUSH, 0);
      }
    }

    // A lane frame the filter forwarded. The gateway answers it, and may write
    // a push first, so replies and pushes interleave as they do on a page.
    on eGwFrame do (f: tGwFrame) {
      announce eGwReceived, (n = f.n, pieces = f.pieces, total = f.total, cmd = f.cmd);
      if (attached == 1) {
        if (choose(2) == 0) {
          write(1, FK_PUSH, 0);
        }
        write(1, FK_REPLY, f.n);
      }
    }

    // The relayed door of the hub: the only door a decision from the page may use.
    on eRelayedDecide do (r: (src: machine, n: int)) {
      announce eDecided, (door = DOOR_RELAYED, caller = r.src);
      send r.src, eHubDone, r.n;
    }

    // The local door of the hub: the box owner's own approve.
    on eLocalApprove do (src: machine) {
      announce eDecided, (door = DOOR_LOCAL, caller = src);
    }

    // The feed host lapsed or the page detached, so the attachment is dropped.
    on eGwDetach do {
      announce eGwDetached;
      attached = 0;
    }

    // The session stopped or the spawner's access was revoked. The gateway's
    // attachment ends and the feed host is told why.
    on eStopSession do {
      attached = 0;
      send host, eEndFeed, EN_STOPPED;
    }

    on eRevoke do {
      attached = 0;
      send host, eEndFeed, EN_REVOKED;
    }

    on eFlush do (c: machine) {
      send c, eAck;
    }

    on eTick do (c: machine) {
      send c, eAck;
    }
  }

  fun write(size: int, fk: tFrameKind, req: int) {
    var gid: int;
    gid = nextGid;
    nextGid = nextGid + 1;
    announce eWritten, gid;
    send host, eSink, (gid = gid, size = size, fk = fk, req = req);
  }
}
