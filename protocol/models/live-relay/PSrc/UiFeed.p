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
// An answer that reports the feed ended delivers none of its frames, whatever it
// carries: an honest box sends none, and a box that sends some is not believed.
//
// Pacing. An answer that carries no frame is followed by the next poll one
// `IdlePause` later and not at once. An honest box answers empty only after its
// hold, so the pause costs nothing, and a box that answers empty at once cannot
// drive a tight loop.
//
// Showing. A page of a session on another orchestrator cannot tell a link that is
// down from one that is slow, so when the lane fails and closes the page it shows
// the waiting state, never a failure. The component decides that, in the same
// update that ends its lane, and this machine states the rule: the shown kind is
// always waiting, whatever the link did.
//
// Ending. When the feed ends, its outbox ends with it. A frame the lane had
// queued is not sent again by anything, so no piece leaves after the end, and a
// later feed starts with an empty outbox.
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
  var paused: int;
  var pauseAge: int;

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

    // The lane failed and the page is closed. What the page shows depends on
    // whether the link is down.
    on eLaneShut do {
      if (dead == 0 && closed == 0) {
        closed = 1;
        announce eShown, showKind();
        send link, eToBox, (kind = RQ_DETACH, pollId = 0, after = 0, wait = 0, n = 0, offset = 0, total = 0, cmd = CMD_FORWARD);
      }
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
      announce eUiTick;
      if (dead == 0 && closed == 0) {
        if (paused == 1) {
          pauseAge = pauseAge + 1;
          if (pauseAge >= IdlePause()) {
            paused = 0;
            sendPoll();
          }
        }
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
    announce ePollSent;
    pollId = pollId + 1;
    pollOut = 1;
    pollAge = 0;
    send link, eToBox, (kind = RQ_POLL, pollId = pollId, after = after, wait = Wait(), n = 0, offset = 0, total = 0, cmd = CMD_FORWARD);
  }

  fun sendPiece() {
    announce ePieceOut;
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
    // An answer that reports the feed ended delivers nothing.
    if (end == 0) {
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
    } else if (sizeof(m.frames) > 0) {
      announce eDroppedEnded;
    }
    if (dead == 1) {
      return;
    }
    if (m.ended != EN_NONE) {
      finish(m.ended);
      return;
    }
    // An answer with no frame is followed by a pause, and one with frames by the
    // next poll at once.
    if (sizeof(m.frames) == 0) {
      announce eEmptyAnswer;
      paused = 1;
      pauseAge = 0;
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

  fun showKind(): tShown {
    return SH_WAITING;
  }

  fun finish(kind: tEnded) {
    dead = 1;
    announce eFeedDone, sizeof(outq);
    outq = default(seq[tOut]);
    send lane, eUiEnded, kind;
  }
}
