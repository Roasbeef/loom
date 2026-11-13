// The box's feed host for one feed (protocol-change/108, "The box's feed host").
//
// It holds the numbered queue of frames the laptop has not acknowledged, the
// lease, the held poll, the receipt of lane frames in pieces, and the filter
// that decides what a completed lane frame becomes. It answers only requests,
// and never sends to the laptop unasked: a held poll is released by an arrival,
// a tick or an ending, and all of those answer the poll that is held.
//
// Time is in ticks, which the Clock sends. `idle` counts ticks since a poll
// arrived. A feed lapses when the queue passes its bound or `idle` reaches the
// lease. The lease is renewed by a poll's arrival and by nothing else: releasing
// a held poll does not renew it. A poll whose `after` is ahead of the queue or
// behind what was acknowledged is refused, and renews nothing. An ended feed
// keeps its token, its process and its place for one more lease, then is
// forgotten, and a request for a forgotten token is refused. A detach ends the
// feed and exits at once, so it is forgotten at once. Every ending detaches the
// gateway door exactly once.
//
// A feed starts when its tick `attachAt` comes: it asks the directory for a
// place, and a feed that is refused never runs. A feed with no directory has its
// place at once.
machine FeedHost {
  var link: machine;
  var gateway: machine;
  var directory: machine;
  var attachAt: int;
  var tickN: int;
  // 0 waiting to attach, 1 asked for a place, 2 running, 3 refused a place.
  var life: int;
  var queue: seq[tFrame];
  var qbytes: int;
  var nextNum: int;
  var floor: int;
  var idle: int;
  var held: int;
  var heldId: int;
  var heldWait: int;
  var heldAge: int;
  var ended: tEnded;
  var endedAge: int;
  var forgotten: int;
  var recvN: int;
  var recvOff: int;
  var hostGid: int;
  var hostile: int;
  var spare: seq[tFrame];

  start state Running {
    entry (p: (link: machine, gateway: machine, directory: machine, attachAt: int, hostile: int)) {
      link = p.link;
      gateway = p.gateway;
      directory = p.directory;
      attachAt = p.attachAt;
      hostile = p.hostile;
      if (attachAt == 0) {
        begin();
      }
    }

    // The directory granted the place: the feed runs.
    on eReserved do {
      life = 2;
      nextNum = 1;
      recvN = 1;
      hostGid = 1000;
      announce eFeedStarted, this;
    }

    // The directory refused: the spawner holds as many feeds as the cap allows.
    on eCapRefused do {
      life = 3;
      announce eAttachRefused;
    }

    on eReq do (m: tReq) {
      if (life == 2) {
        if (m.kind == RQ_POLL) {
          poll(m);
        } else if (m.kind == RQ_SEND) {
          piece(m);
        } else {
          detach();
        }
      }
    }

    // A frame the gateway wrote. Frames that arrive after the feed ended were
    // written to a sink nobody reads and are discarded.
    on eSink do (f: tSink) {
      if (life == 2 && ended == EN_NONE) {
        admit(f);
      }
    }

    // The gateway's attachment ended: the session stopped or access was revoked.
    on eEndFeed do (kind: tEnded) {
      if (life == 2 && ended == EN_NONE) {
        endFeed(kind);
      }
    }

    // The hub judged an `approve` through the relayed door. The feed host
    // writes the answer as a reply frame, with the lane's request number.
    on eHubDone do (n: int) {
      if (life == 2 && ended == EN_NONE) {
        writeOwn(n);
      }
    }

    on eTick do (c: machine) {
      tickN = tickN + 1;
      if (life == 0 && tickN >= attachAt) {
        begin();
      }
      if (life == 2 && ended == EN_NONE) {
        idle = idle + 1;
        if (held == 1) {
          heldAge = heldAge + 1;
          if (heldAge >= heldWait) {
            held = 0;
            answerPoll(heldId, default(seq[tFrame]), EN_NONE);
          }
        }
        if (idle >= Lease()) {
          lapse(1);
        }
      } else if (life == 2) {
        endedAge = endedAge + 1;
        if (endedAge >= Lease() && forgotten == 0) {
          forget();
        }
      }
      send c, eAck;
    }

    on eFlush do (c: machine) {
      send c, eAck;
    }
  }

  // A feed asks for its place, or has one at once when no directory counts.
  fun begin() {
    life = 1;
    if (directory == null) {
      life = 2;
      nextNum = 1;
      recvN = 1;
      hostGid = 1000;
      announce eFeedStarted, this;
    } else {
      send directory, eReserve, this;
    }
  }

  // The feed's process exits: its token is forgotten and its place is free.
  fun forget() {
    forgotten = 1;
    announce eForgotten;
    if (directory != null) {
      send directory, eFeedGone;
    }
    announce eFeedExited;
  }

  // A poll acknowledges the frames the laptop received, then answers the frames
  // beyond `after` or holds. A poll that arrives while another is held releases
  // the held one with an empty answer, before its own cursor is judged. A cursor
  // the queue cannot honour is refused and changes nothing, and renews nothing.
  fun poll(m: tReq) {
    if (forgotten == 1) {
      announce eRefusedForgotten;
      refuse(m);
      return;
    }
    if (ended != EN_NONE) {
      answerPoll(m.pollId, leftover(), ended);
      return;
    }
    if (held == 1) {
      held = 0;
      announce eSuperseded;
      answerPoll(heldId, default(seq[tFrame]), EN_NONE);
    }
    if (m.after > nextNum - 1) {
      announce eCursorRefused, 0;
      refuse(m);
      return;
    }
    if (m.after < floor) {
      announce eCursorRefused, 1;
      refuse(m);
      return;
    }
    idle = 0;
    floor = m.after;
    dropAcked(m.after);
    if (sizeof(queue) > 0) {
      deliverQueue(m.pollId);
    } else {
      held = 1;
      heldId = m.pollId;
      heldWait = m.wait;
      heldAge = 0;
    }
  }

  // One piece of a lane frame. A piece already admitted is answered again and
  // changes nothing. A piece out of order, or for a frame other than the next,
  // is refused. The last piece completes the frame and hands it to the filter.
  fun piece(m: tReq) {
    if (ended != EN_NONE) {
      refuse(m);
      return;
    }
    if (m.n < recvN || (m.n == recvN && m.offset < recvOff)) {
      announce eRepeatPiece;
      // A repeated piece changes nothing and is answered again.
      sendAck(m);
      return;
    }
    if (m.n != recvN || m.offset != recvOff) {
      refuse(m);
      return;
    }
    recvOff = recvOff + 1;
    sendAck(m);
    if (recvOff == m.total) {
      filter(m.n, m.cmd, recvOff, m.total);
      recvN = recvN + 1;
      recvOff = 0;
    }
  }

  // The closed table. A forwardable command goes to the gateway, an approval
  // goes to the hub's relayed door, and everything else is answered forbidden
  // by the feed host itself.
  fun filter(n: int, cmd: tCmd, pieces: int, total: int) {
    if (cmd == CMD_FORWARD) {
      send gateway, eGwFrame, (n = n, cmd = cmd, pieces = pieces, total = total);
    } else if (cmd == CMD_APPROVE) {
      send gateway, eRelayedDecide, (src = this, n = n);
    } else {
      writeOwn(n);
    }
  }

  // Detach is idempotent. It ends a live feed, which detaches the gateway door
  // once, and the feed's process exits, so the token is forgotten at once and a
  // later request for it is refused. A detach of a feed that is gone answers null.
  fun detach() {
    if (ended == EN_NONE) {
      endFeed(EN_DETACHED);
    }
    if (forgotten == 0) {
      forget();
    }
    send link, eToLaptop, (kind = AN_DETACH, pollId = 0, frames = default(seq[tFrame]), ended = EN_NONE, n = 0, offset = 0);
  }

  // Admission to the queue. An empty queue admits any frame an answer can carry,
  // and a frame that would pass the frame count or the byte bound lapses the feed.
  fun admit(f: tSink) {
    var fr: tFrame;
    if (sizeof(queue) > 0 && (sizeof(queue) + 1 > MaxFrames() || qbytes + f.size > MaxBytes())) {
      lapse(0);
      return;
    }
    fr = (n = nextNum, gid = f.gid, size = f.size, fk = f.fk, req = f.req);
    nextNum = nextNum + 1;
    queue += (sizeof(queue), fr);
    qbytes = qbytes + f.size;
    announce eAdmitted, (gid = f.gid, size = f.size);
    if (held == 1) {
      held = 0;
      deliverQueue(heldId);
    }
  }

  // A frame the feed host answers itself, such as a forbidden reply or the
  // reply to a decision. It takes the next number in the same queue.
  fun writeOwn(n: int) {
    hostGid = hostGid + 1;
    admit((gid = hostGid, size = 1, fk = FK_REPLY, req = n));
  }

  fun dropAcked(after: int) {
    var keep: seq[tFrame];
    var f: tFrame;
    var bytes: int;
    foreach (f in queue) {
      if (f.n > after) {
        keep += (sizeof(keep), f);
        bytes = bytes + f.size;
      }
    }
    queue = keep;
    qbytes = bytes;
  }

  // Answers every frame in the queue. Frames the laptop acknowledged leave the
  // queue on a later poll's `after`, never here, so an answer that is lost is
  // answered again.
  fun deliverQueue(id: int) {
    answerPoll(id, queue, EN_NONE);
    // The queue is kept until a later poll acknowledges it.
  }

  fun answerPoll(id: int, frames: seq[tFrame], kind: tEnded) {
    var he: int;
    if (ended != EN_NONE && hostile == 0) {
      he = 1;
    }
    announce eAnswerSent, (count = sizeof(frames), hostEnded = he);
    send link, eToLaptop, (kind = AN_POLL, pollId = id, frames = frames, ended = kind, n = 0, offset = 0);
  }

  fun sendAck(m: tReq) {
    send link, eToLaptop, (kind = AN_SEND, pollId = 0, frames = default(seq[tFrame]), ended = EN_NONE, n = m.n, offset = m.offset);
  }

  fun refuse(m: tReq) {
    send link, eToLaptop, (kind = AN_REFUSED, pollId = m.pollId, frames = default(seq[tFrame]), ended = ended, n = m.n, offset = m.offset);
  }

  // A lapse drops the queue and the partial frame, detaches from the gateway, and
  // keeps the ended token for one more lease. `cause` is 0 for the bound and 1 for
  // the lease.
  fun lapse(cause: int) {
    announce eLapse, cause;
    endFeed(EN_LAPSED);
  }

  // What a box that is not honest keeps to answer with after the feed ended:
  // the queue it had. An honest box keeps nothing, and answers no frames.
  fun leftover(): seq[tFrame] {
    if (hostile == 1) {
      return spare;
    }
    return default(seq[tFrame]);
  }


  // The one place a feed ends. It detaches the gateway door once, drops the queue
  // and the partial frame, and answers a held poll with the ending.
  fun endFeed(kind: tEnded) {
    send gateway, eGwDetach;
    ended = kind;
    endedAge = 0;
    if (hostile == 1) {
      spare = queue;
    }
    queue = default(seq[tFrame]);
    qbytes = 0;
    recvOff = 0;
    announce eFeedEnded, kind;
    if (held == 1) {
      held = 0;
      answerPoll(heldId, leftover(), kind);
    }
  }
}
