// The laptop's feed adapter (`ui_feed`, protocol-change/108, "The laptop's socket
// adapter"). It keeps at most one poll and one send in flight.
//
// Polling. It polls with `after`, the number of the last frame it delivered.
// An answer for the poll in flight delivers each frame numbered `after + 1` in
// turn and ignores a frame numbered `after` or less. An answer for any other
// poll, and a second copy of an answer, is dropped. A poll with no answer after
// `PollTimeout` ticks is sent again with the same `after`. A frame numbered more
// than `after + 1` is a gap, which an honest box never produces: the adapter
// ends the feed and reports it.
//
// Sending. It sends the pieces of one lane frame in order, one in flight. A
// piece with no answer after `SendTimeout` ticks is sent again unchanged. It
// sends frame n + 1 only after every piece of frame n was admitted.
//
// An answer or a refusal that says the feed ended ends the adapter and the lane.
machine UiFeed {
  var link: machine;
  var lane: machine;
  var after: int;
  var pollId: int;
  var pollOut: int;
  var pollAge: int;
  var sendOut: int;
  var sendAge: int;
  var outq: seq[tOut];
  var curOff: int;
  var closed: int;
  var dead: int;

  start state Running {
    entry (l: machine) {
      link = l;
    }

    on eUiWire do (l: machine) {
      lane = l;
    }

    on eOpen do {
      sendPoll();
    }

    on eClose do {
      closed = 1;
      send link, eToBox, (kind = RQ_DETACH, pollId = 0, after = 0, wait = 0, n = 0, offset = 0, total = 0, cmd = CMD_FORWARD);
      send link, eToBox, (kind = RQ_DETACH, pollId = 0, after = 0, wait = 0, n = 0, offset = 0, total = 0, cmd = CMD_FORWARD);
    }

    on eLaneSubmit do (o: tOut) {
      if (dead == 0 && closed == 0) {
        outq += (sizeof(outq), o);
        pump();
      }
    }

    on eAns do (m: tAns) {
      if (dead == 1 || closed == 1) {
        return;
      }
      if (m.kind == AN_POLL) {
        onPoll(m);
      } else if (m.kind == AN_SEND) {
        onSend(m);
      } else if (m.kind == AN_REFUSED) {
        // A refusal that names an ending ends the adapter. A refusal of a poll
        // that is no longer in flight is a delayed copy of an old poll, whose
        // cursor the box has since passed, and is dropped. Any other refusal, of
        // the poll in flight or of a piece, ends the adapter.
        if (m.ended != EN_NONE) {
          finish(m.ended);
        } else if (m.pollId == 0 || (m.pollId == pollId && pollOut == 1)) {
          finish(EN_NONE);
        }
      }
    }

    on eTick do (c: machine) {
      if (dead == 0 && closed == 0) {
        if (pollOut == 1) {
          pollAge = pollAge + 1;
          if (pollAge >= PollTimeout()) {
            sendPoll();
          }
        }
        if (sendOut == 1) {
          sendAge = sendAge + 1;
          if (sendAge >= SendTimeout()) {
            sendPiece();
          }
        }
      }
      send c, eAck;
    }

    on eFlush do (c: machine) {
      send c, eAck;
    }
  }

  fun sendPoll() {
    pollId = pollId + 1;
    pollOut = 1;
    pollAge = 0;
    send link, eToBox, (kind = RQ_POLL, pollId = pollId, after = after, wait = Wait(), n = 0, offset = 0, total = 0, cmd = CMD_FORWARD);
  }

  fun sendPiece() {
    sendOut = 1;
    sendAge = 0;
    send link, eToBox, (kind = RQ_SEND, pollId = 0, after = 0, wait = 0, n = outq[0].n, offset = curOff, total = outq[0].total, cmd = outq[0].cmd);
  }

  fun pump() {
    if (dead == 0 && closed == 0 && sendOut == 0 && sizeof(outq) > 0) {
      sendPiece();
    }
  }

  fun onPoll(m: tAns) {
    var f: tFrame;
    var end: int;
    if (m.pollId != pollId || pollOut == 0) {
      return;
    }
    pollOut = 0;
    if (m.ended != EN_NONE) {
      end = 1;
    }
    foreach (f in m.frames) {
      if (dead == 0 && f.n > after) {
        if (f.n == after + 1) {
          after = f.n;
          announce eDelivered, (gid = f.gid, endAnswer = end);
          send lane, eDeliver, f;
        } else {
          announce eGapObserved;
          finish(EN_NONE);
        }
      }
    }
    if (dead == 1) {
      return;
    }
    if (m.ended != EN_NONE) {
      finish(m.ended);
      return;
    }
    sendPoll();
  }

  fun onSend(m: tAns) {
    if (sendOut == 1 && sizeof(outq) > 0 && m.n == outq[0].n && m.offset == curOff) {
      sendOut = 0;
      curOff = curOff + 1;
      if (curOff == outq[0].total) {
        outq -= (0);
        curOff = 0;
      }
      pump();
    }
  }

  fun finish(kind: tEnded) {
    dead = 1;
    send lane, eUiEnded, kind;
  }
}
