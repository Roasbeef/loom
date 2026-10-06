// One original resource owner handles control independently of a stalled data
// leaf. Complete frames are byte-count atoms; no OS write or codec runs in P.
machine LaunchChannel {
  var driver: machine;
  var rows: map[int, tRow];
  var lanes: map[(id: int, direction: tDirection), tLane];
  var metadata: set[int];
  var active: int;
  var current: tCommand;

  start state Ready {
    entry (owner: machine) { driver = owner; }
    on eCommand do (p: tCommand) {
      current = p;
      if (p.action == MetadataReserve || p.action == MetadataRelease) { metadataCommand(p); return; }
      if (p.action == Prepare) { prepare(p); return; }
      if (!(p.identity.id in rows) || rows[p.identity.id].identity != p.identity) {
        view(p.identity, Refused); return;
      }
      dispatch(p);
    }
  }

  fun prepare(p: tCommand) {
    var row: tRow; var lane: tLane;
    if (p.identity.id in rows || active >= 4 || p.identity.incarnation != 7 ||
        p.identity.scope != 1 || p.identity.generation != 3 ||
        (p.identity.binding == RemoteBinding && p.identity.service != 100 + p.identity.id) ||
        (p.identity.binding == LocalBinding && p.identity.service != 0)) {
      view(p.identity, Refused); return;
    }
    row = default(tRow); row.identity = p.identity; row.phase = PreparedPaused;
    row.ownerAlive = true; rows[p.identity.id] = row;
    lane = default(tLane); lane.window = PreparedWindow;
    lanes[(id = p.identity.id, direction = ToOwner)] = lane;
    lanes[(id = p.identity.id, direction = ToSocket)] = lane;
    active = active + 1; announce mPrepared, p.identity; view(p.identity, Applied);
  }

  fun dispatch(p: tCommand) {
    var row: tRow;
    row = rows[p.identity.id];
    if (p.action == HistoricalQuery) { announce mHistory, p.identity; view(p.identity, Applied); return; }
    if (p.action == Reconnect) { view(p.identity, Refused); return; }
    if (p.action == Snapshot) { view(p.identity, Applied); return; }
    if (p.action == AcceptCustody) {
      if (row.phase != PreparedPaused || row.custody || !row.ownerAlive) { view(p.identity, Refused); return; }
      rows[p.identity.id].custody = true; announce mCustody, p.identity;
    } else if (p.action == Activate) {
      if (row.phase != PreparedPaused || !row.custody || row.activated || !row.ownerAlive) { view(p.identity, Refused); return; }
      rows[p.identity.id].activated = true; rows[p.identity.id].phase = Active;
      lanes[(id = p.identity.id, direction = ToOwner)].window = Available;
      lanes[(id = p.identity.id, direction = ToSocket)].window = Available;
      announce mActivated, p.identity;
    } else if (p.action == ReserveFrame) { reserve(p); return;
    } else if (p.action == AdmitReply) { reply(p); return;
    } else if (p.action == DeliverFrame) { deliver(p); return;
    } else if (p.action == ChunkAck) {
      announce mChunk, key(p);
    } else if (p.action == HostAdmit) { host(p); return;
    } else if (p.action == SocketConsume) { socket(p); return;
    } else if (p.action == ReceiveAck) { ack(p); return;
    } else if (p.action == CapDone) {
      if (row.phase != Active || !(p.call in row.calls) || row.calls[p.call].disposition != Running) { view(p.identity, Refused); return; }
      if (p.payload <= 0 || p.payload > payloadLimit()) { retire(p.identity); view(p.identity, Refused); return; }
      rows[p.identity.id].calls[p.call].wireBytes = p.payload + 4;
      rows[p.identity.id].calls[p.call].settled = true;
      rows[p.identity.id].calls[p.call].disposition = ReplyReady;
      announce mCallSettled, (identity = p.identity, call = p.call);
    } else if (p.action == EndChannel) {
      orderedEnd(p); return;
    } else if (p.action == DestroyBegin) {
      if (row.phase != Terminating && row.phase != Closing) { view(p.identity, Refused); return; }
      destroy(p.identity);
    } else if (p.action == Cancel || p.action == RecipientDeath) {
      announce mCancelRequested, p.identity;
      retire(p.identity); destroy(p.identity); announce mCancelReturned, p.identity;
    } else if (p.action == OwnerDeath) {
      rows[p.identity.id].ownerAlive = false; retire(p.identity);
    } else if (p.action == ReaderJoin || p.action == WriterJoin) {
      if (!row.destroying || !row.socketClosed || !row.ownerAlive) { view(p.identity, Refused); return; }
      if (p.action == ReaderJoin) { rows[p.identity.id].readerJoined = true; }
      else { rows[p.identity.id].writerJoined = true; }
      announce mJoined, (identity = p.identity, reader = p.action == ReaderJoin);
      releaseEntry(p.identity);
    } else if (p.action == NativeRetire) {
      if (!row.ownerAlive) { view(p.identity, Refused); return; }
      rows[p.identity.id].nativeRetired = true; announce mNative, p.identity;
      releaseEntry(p.identity);
    } else if (p.action == ResourcesRelease) {
      if (!row.ownerAlive || !row.socketClosed) { view(p.identity, Refused); return; }
      rows[p.identity.id].resourcesReleased = true; announce mResources, p.identity;
      releaseEntry(p.identity);
    } else if (p.action == CleanupSafe) {
      if (!row.resourcesReleased || !row.readerJoined || !row.writerJoined || !row.nativeRetired) { view(p.identity, Refused); return; }
      rows[p.identity.id].cleanupSafe = true; announce mCleanup, p.identity;
    } else if (p.action == DeleteDirectory) {
      if (!row.cleanupSafe) { view(p.identity, Refused); return; }
      announce mDirectoryDeleted, p.identity;
    } else if (p.action == ReportCommit) {
      if (!row.terminal || row.reportCommitted) { view(p.identity, Refused); return; }
      rows[p.identity.id].reportCommitted = true; announce mReport, p.identity;
    } else if (p.action == PublishFinal) {
      if (!row.reportCommitted) { view(p.identity, Refused); return; }
      announce mPublished, p.identity;
    }
    view(p.identity, Applied);
  }

  fun reserve(p: tCommand) {
    var lane: tLane; var frame: tFrame; var bytes: int;
    lane = lanes[(id = p.identity.id, direction = p.direction)]; bytes = p.payload + 4;
    if (rows[p.identity.id].phase != Active || lane.window != Available || p.direction != ToOwner) { view(p.identity, Refused); return; }
    if (p.payload < 0 || p.payload > payloadLimit() || lane.spent + bytes > lifetimeLimit()) {
      retire(p.identity); view(p.identity, Refused); return;
    }
    frame = (key = (identity = p.identity, direction = p.direction, sequence = lane.sequence + 1),
      wireBytes = bytes, kind = p.kind, call = p.call, delivered = false, consumed = false, final = false);
    hold(frame); view(p.identity, Applied);
  }

  fun hold(frame: tFrame) {
    var address: (id: int, direction: tDirection);
    address = (id = frame.key.identity.id, direction = frame.key.direction);
    lanes[address].window = Reserved; lanes[address].sequence = frame.key.sequence;
    lanes[address].spent = lanes[address].spent + frame.wireBytes;
    lanes[address].frame = frame; announce mReserved, frame;
  }

  fun deliver(p: tCommand) {
    var address: (id: int, direction: tDirection); var lane: tLane;
    address = (id = p.identity.id, direction = p.direction); lane = lanes[address];
    if (rows[p.identity.id].phase != Active || lane.window != Reserved ||
        lane.frame.key != key(p) || lane.frame.delivered) { view(p.identity, Refused); return; }
    lanes[address].window = Pending; lanes[address].frame.delivered = true; announce mDelivered, lanes[address].frame;
    view(p.identity, Applied);
  }

  fun host(p: tCommand) {
    var row: tRow; var lane: tLane; var call: tCall;
    row = rows[p.identity.id]; lane = lanes[(id = p.identity.id, direction = ToOwner)];
    if (row.phase != Active || p.direction != ToOwner || lane.window != Pending ||
        lane.frame.key != key(p) || !lane.frame.delivered || lane.frame.consumed) { view(p.identity, Refused); return; }
    if (lane.frame.kind == CallRequest) {
      if (sizeof(row.calls) >= 2 || lane.frame.call in row.calls) { view(p.identity, Refused); return; }
      call = (disposition = Running, settled = false, sequence = 0, wireBytes = 0);
      rows[p.identity.id].calls[lane.frame.call] = call;
      announce mCallAdmitted, (identity = p.identity, call = lane.frame.call);
      consume(p.identity, ToOwner, false);
    } else if (lane.frame.kind == ImmediateRequest) {
      if (row.immediate) { view(p.identity, Refused); return; }
      rows[p.identity.id].immediate = true;
      rows[p.identity.id].immediateInbound = lane.frame.key;
      announce mImmediateHeld, lane.frame;
    } else if (lane.frame.kind == TerminalFrame) {
      rows[p.identity.id].terminal = true; rows[p.identity.id].phase = Terminating;
      announce mTerminalValidated, lane.frame;
      consume(p.identity, ToOwner, true);
    } else if (lane.frame.kind == MalformedFrame) { retire(p.identity);
    } else if (lane.frame.kind == IgnoredFrame) { consume(p.identity, ToOwner, false);
    } else { view(p.identity, Refused); return; }
    view(p.identity, Applied);
  }

  fun consume(id: tIdentity, direction: tDirection, final: bool) {
    var address: (id: int, direction: tDirection);
    address = (id = id.id, direction = direction);
    lanes[address].frame.consumed = true; lanes[address].frame.final = final;
    if (direction == ToOwner) { announce mHostConsumed, lanes[address].frame; }
    else { announce mSocketConsumed, lanes[address].frame; }
    announce mAckSent, lanes[address].frame;
    if (final) { rows[id.id].terminalAck = true; }
  }

  fun reply(p: tCommand) {
    var row: tRow; var lane: tLane; var frame: tFrame; var bytes: int;
    row = rows[p.identity.id]; lane = lanes[(id = p.identity.id, direction = ToSocket)]; bytes = p.payload + 4;
    if (row.phase != Active || lane.window != Available) { view(p.identity, Refused); return; }
    if (p.payload <= 0 || p.payload > payloadLimit() || lane.spent + bytes > lifetimeLimit()) {
      retire(p.identity); view(p.identity, Refused); return;
    }
    if (p.kind == CallReply) {
      if (!(p.call in row.calls) || row.calls[p.call].disposition != ReplyReady ||
          p.call != lowestReady(row.calls) || row.calls[p.call].wireBytes != bytes) { view(p.identity, Refused); return; }
      rows[p.identity.id].calls[p.call].disposition = ReplySending;
      rows[p.identity.id].calls[p.call].sequence = lane.sequence + 1;
    } else if (p.kind == ImmediateReply) {
      if (!row.immediate || row.immediateSending) { view(p.identity, Refused); return; }
      rows[p.identity.id].immediateSending = true;
    } else { view(p.identity, Refused); return; }
    frame = (key = (identity = p.identity, direction = ToSocket, sequence = lane.sequence + 1),
      wireBytes = bytes, kind = p.kind, call = p.call, delivered = false, consumed = false, final = false);
    hold(frame); announce mReplyAdmitted, frame; view(p.identity, Applied);
  }

  fun socket(p: tCommand) {
    var lane: tLane;
    lane = lanes[(id = p.identity.id, direction = ToSocket)];
    if (rows[p.identity.id].phase != Active || p.direction != ToSocket || lane.window != Pending ||
        lane.frame.key != key(p) || !lane.frame.delivered || lane.frame.consumed) { view(p.identity, Refused); return; }
    consume(p.identity, ToSocket, false); view(p.identity, Applied);
  }

  fun ack(p: tCommand) {
    var address: (id: int, direction: tDirection); var lane: tLane; var id: int;
    id = p.identity.id; address = (id = id, direction = p.direction); lane = lanes[address];
    if (lane.window != Pending || lane.frame.key != key(p) || !lane.frame.consumed ||
        (rows[id].phase != Active && !(rows[id].phase == Terminating && lane.frame.final))) { view(p.identity, Refused); return; }
    announce mAckApplied, (current = lane.frame, source = key(p));
    if (lane.frame.final) { lanes[address].window = Finished;
    } else {
      lanes[address].window = Available; announce mFreed, lane.frame;
    }
    if (p.direction == ToSocket && lane.frame.kind == CallReply) {
      rows[id].calls -= (lane.frame.call);
      announce mCallReleased, (identity = p.identity, call = lane.frame.call);
    } else if (p.direction == ToSocket && lane.frame.kind == ImmediateReply) {
      rows[id].immediate = false; rows[id].immediateSending = false;
      announce mImmediateReleased, p.identity; consume(p.identity, ToOwner, false);
    }
    view(p.identity, Applied);
  }

  fun orderedEnd(p: tCommand) {
    var lane: tLane;
    lane = lanes[(id = p.identity.id, direction = ToOwner)];
    if ((rows[p.identity.id].phase != Active && rows[p.identity.id].phase != Terminating) ||
        p.direction != ToOwner || p.sequence != lane.sequence ||
        (lane.window != Available && lane.window != Finished)) { view(p.identity, Refused); return; }
    announce mEnd, key(p); retire(p.identity); view(p.identity, Applied);
  }

  fun retire(id: tIdentity) {
    if (rows[id.id].phase == Retired) { return; }
    rows[id.id].phase = Closing;
    lanes[(id = id.id, direction = ToOwner)].window = WindowRetired;
    lanes[(id = id.id, direction = ToSocket)].window = WindowRetired;
    announce mRetired, id;
  }

  fun destroy(id: tIdentity) {
    if (rows[id.id].destroying) { return; }
    announce mDestroy, id; rows[id.id].destroying = true;
    rows[id.id].phase = Closing;
    lanes[(id = id.id, direction = ToOwner)].window = WindowRetired;
    lanes[(id = id.id, direction = ToSocket)].window = WindowRetired;
    if (rows[id.id].ownerAlive) {
      rows[id.id].socketClosed = true; announce mSocketClosed, id;
    }
  }

  fun releaseEntry(id: tIdentity) {
    var row: tRow;
    row = rows[id.id];
    if (row.phase == Retired || !row.destroying || !row.socketClosed ||
        !row.readerJoined || !row.writerJoined || !row.nativeRetired || !row.resourcesReleased) { return; }
    rows[id.id].phase = Retired; active = active - 1; announce mEntryReleased, id;
  }

  fun metadataCommand(p: tCommand) {
    var slot: int;
    slot = p.call;
    if (p.action == MetadataRelease) {
      if (!(slot in metadata)) { view(p.identity, Refused); return; }
      metadata -= (slot); announce mMetadata, (slot = slot, reserve = false, stream = false);
    } else {
      if (p.payload != 0 || slot < 0 || slot >= 6 || slot in metadata) { view(p.identity, Refused); return; }
      metadata += (slot); announce mMetadata, (slot = slot, reserve = true, stream = p.payload != 0);
    }
    view(p.identity, Applied);
  }

  fun lowestReady(calls: map[int, tCall]): int {
    var entries: seq[int]; var i: int; var answer: int;
    entries = keys(calls); answer = 0;
    while (i < sizeof(entries)) {
      if (calls[entries[i]].disposition == ReplyReady && (answer == 0 || entries[i] < answer)) { answer = entries[i]; }
      i = i + 1;
    }
    return answer;
  }

  fun key(p: tCommand): tFrameKey {
    return (identity = p.identity, direction = p.direction, sequence = p.sequence);
  }

  fun view(id: tIdentity, outcome: tOutcome) {
    var row: tRow; var inbound: tLane; var outbound: tLane; var i: int; var dataSlots: int; var control: int; var answer: tView;
    dataSlots = 4; control = 2;
    while (i < 6) { if (i in metadata) { if (i < 4) { dataSlots = dataSlots - 1; } else { control = control - 1; } } i = i + 1; }
    row = default(tRow); inbound = default(tLane); outbound = default(tLane);
    if (id.id in rows) {
      row = rows[id.id]; inbound = lanes[(id = id.id, direction = ToOwner)]; outbound = lanes[(id = id.id, direction = ToSocket)];
    }
    answer = (outcome = outcome, identity = id, phase = row.phase, calls = sizeof(row.calls),
      immediate = row.immediate, inWindow = inbound.window, outWindow = outbound.window,
      inSpent = inbound.spent, outSpent = outbound.spent, active = active, dataSlots = dataSlots, control = control);
    announce mDecision, (command = current, outcome = outcome);
    announce mSnapshot, answer; send driver, eView, answer;
  }
}
