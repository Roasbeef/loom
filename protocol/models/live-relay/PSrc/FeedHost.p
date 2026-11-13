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
// lease. An ended feed keeps its token for one more lease, then forgets it, and
// a request for a forgotten token is refused.
machine FeedHost {
  var link: machine;
  var gateway: machine;
  var queue: seq[tFrame];
  var qbytes: int;
  var nextNum: int;
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
    entry (p: (link: machine, gateway: machine, hostile: int)) {
      link = p.link;
      gateway = p.gateway;
      hostile = p.hostile;
      nextNum = 1;
      recvN = 1;
      hostGid = 1000;
      announce eFeedStarted, this;
    }

    on eReq do (m: tReq) {
      if (m.kind == RQ_POLL) {
        poll(m);
      } else if (m.kind == RQ_SEND) {
        piece(m);
      } else {
        detach();
      }
    }

    // A frame the gateway wrote. Frames that arrive after the feed ended were
    // written to a sink nobody reads and are discarded.
    on eSink do (f: tSink) {
      if (ended == EN_NONE) {
        admit(f);
      }
    }

    // The gateway's attachment ended: the session stopped or access was revoked.
    on eEndFeed do (kind: tEnded) {
      if (ended == EN_NONE) {
        endFeed(kind);
      }
    }

    // The hub judged an `approve` through the relayed door. The feed host
    // writes the answer as a reply frame, with the lane's request number.
    on eHubDone do (n: int) {
      if (ended == EN_NONE) {
        writeOwn(n);
      }
    }

    on eTick do (c: machine) {
      if (ended == EN_NONE) {
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
      } else {
        endedAge = endedAge + 1;
        if (endedAge >= Lease() && forgotten == 0) {
          forgotten = 1;
          announce eForgotten;
        }
      }
      send c, eAck;
    }

    on eFlush do (c: machine) {
      send c, eAck;
    }
  }

  // A poll drops the frames the laptop acknowledged, then answers the frames
  // beyond `after` or holds. A poll that arrives while another is held releases
  // the held one with an empty answer.
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
    idle = 0;
    if (held == 1) {
      held = 0;
      announce eSuperseded;
      answerPoll(heldId, default(seq[tFrame]), EN_NONE);
    }
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

  // Detach is idempotent and answers null for a token no longer held.
  fun detach() {
    if (ended == EN_NONE) {
      send gateway, eGwDetach;
      endFeed(EN_DETACHED);
    }
    send link, eToLaptop, (kind = AN_DETACH, pollId = 0, frames = default(seq[tFrame]), ended = EN_NONE, n = 0, offset = 0);
  }

  // Admission to the queue. An empty queue admits any frame, so a frame larger
  // than the byte bound alone never ends a feed. Otherwise a frame that would
  // pass the frame count or the byte bound lapses the feed.
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

  // A lapse detaches from the gateway, drops the queue and the partial frame,
  // and keeps the ended token for one more lease. `cause` is 0 for the bound and
  // 1 for the lease.
  fun lapse(cause: int) {
    announce eLapse, cause;
    send gateway, eGwDetach;
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

  fun endFeed(kind: tEnded) {
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
