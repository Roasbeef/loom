// Histories are reconstructed from ownership/recipient effects, independently
// of LaunchChannel's private row flags. Native and SQL events are assumptions.
spec ChannelSafety observes mPrepared, mCustody, mActivated, mReserved,
  mDelivered, mChunk, mHostConsumed, mSocketConsumed, mAckSent, mAckApplied,
  mFreed, mCallAdmitted, mCallSettled, mReplyAdmitted, mCallReleased,
  mImmediateHeld, mImmediateReleased, mTerminalValidated, mDestroy,
  mSocketClosed, mCancelRequested, mCancelReturned, mRetired, mJoined,
  mNative, mEnd, mResources, mCleanup, mDirectoryDeleted, mReport, mPublished, mEntryReleased, mMetadata, mSnapshot {
  var originals: map[int, tIdentity]; var live: set[tIdentity];
  var custody: set[tIdentity]; var activated: set[tIdentity]; var retired: set[tIdentity];
  var destroying: set[tIdentity]; var closed: set[tIdentity];
  var reader: set[tIdentity]; var writer: set[tIdentity]; var native: set[tIdentity];
  var resources: set[tIdentity]; var safeCleanup: set[tIdentity];
  var reports: set[tIdentity]; var terminals: set[tIdentity]; var finalAck: set[tIdentity];
  var windows: map[(identity: tIdentity, direction: tDirection), tFrame];
  var last: map[(identity: tIdentity, direction: tDirection), int];
  var spent: map[(identity: tIdentity, direction: tDirection), int];
  var delivered: set[tFrameKey]; var consumed: set[tFrameKey];
  var ackSent: set[tFrameKey]; var acked: set[tFrameKey];
  var calls: map[(identity: tIdentity, call: int), tDisposition];
  var callAck: set[(identity: tIdentity, call: int)];
  var immediate: map[tIdentity, tFrameKey]; var immediateAck: set[tIdentity];
  var metadata: set[int];

  start state Watching {
    on mPrepared do (id: tIdentity) {
      assert !(id.id in originals), "historical Launch recreated its live continuation";
      assert id.incarnation == 7 && id.scope == 1 && id.generation == 3,
        "Launch admitted a foreign original incarnation";
      assert (id.binding == LocalBinding && id.service == 0) ||
        (id.binding == RemoteBinding && id.service == 100 + id.id),
        "local incarnation replaced remote Launch identity";
      originals[id.id] = id; live += (id);
      assert sizeof(live) <= 4, "historical capacity replaced bounded live Launch admission";
    }
    on mCustody do (id: tIdentity) {
      assert id.id in originals && originals[id.id] == id && !(id in custody), "custody did not belong to original prepared connection";
      custody += (id);
    }
    on mActivated do (id: tIdentity) {
      assert id in custody && !(id in activated) && !(id in retired) && !(id in destroying),
        "inbound activated before custody or after original retirement";
      activated += (id);
    }
    on mReserved do (frame: tFrame) {
      var address: (identity: tIdentity, direction: tDirection); var used: int; var prior: int;
      address = (identity = frame.key.identity, direction = frame.key.direction);
      assert frame.key.identity in activated && !(frame.key.identity in retired) &&
        !(frame.key.identity in destroying) && !(frame.key.identity in terminals), "retired or terminal channel resurrected frame credit";
      assert originals[frame.key.identity.id] == frame.key.identity, "frame changed original authenticated identity";
      assert !(address in windows), "second frame entered occupied directional window";
      assert frame.wireBytes >= 4 && frame.wireBytes <= 16777220 && chunkCount(frame.wireBytes) <= 257,
        "frame admission exceeded payload prefix or exact chunk bound";
      used = 0; prior = 0;
      if (address in spent) { used = spent[address]; }
      if (address in last) { prior = last[address]; }
      assert used + frame.wireBytes <= lifetimeLimit(), "direction exceeded cumulative wire-byte allowance";
      assert frame.key.sequence == prior + 1, "frame sequence reused within original incarnation";
      spent[address] = used + frame.wireBytes; last[address] = frame.key.sequence; windows[address] = frame;
    }
    on mDelivered do (frame: tFrame) {
      var address: (identity: tIdentity, direction: tDirection);
      address = (identity = frame.key.identity, direction = frame.key.direction);
      assert frame.key.identity in activated && !(frame.key.identity in retired) &&
        !(frame.key.identity in destroying) && !(frame.key.identity in terminals), "frame delivered before activation or after final retirement";
      assert address in windows && windows[address].key == frame.key &&
        windows[address].wireBytes == frame.wireBytes, "body mailbox delivery preceded original byte reservation";
      assert !(frame.key in delivered), "complete frame delivered twice";
      delivered += (frame.key);
    }
    on mChunk do (key: tFrameKey) {
      // Chunk receipt is deliberately not added to consumed or acked history.
    }
    on mHostConsumed do (frame: tFrame) {
      assert frame.key.direction == ToOwner && frame.key in delivered && !(frame.key in consumed),
        "host consumption did not follow one complete validated frame";
      if (frame.kind == CallRequest) {
        assert (identity = frame.key.identity, call = frame.call) in calls, "call consumed without bounded invocation custody";
      } else if (frame.kind == ImmediateRequest) {
        assert !(frame.key.identity in immediate), "immediate input ACK preceded exact reply consumption";
      } else if (frame.kind == TerminalFrame) {
        assert frame.key.identity in terminals && frame.final, "terminal ACK preceded semantic validation";
      }
      consumed += (frame.key);
    }
    on mSocketConsumed do (frame: tFrame) {
      assert frame.key.direction == ToSocket && frame.key in delivered && !(frame.key in consumed),
        "socket consumption did not follow complete writer frame";
      consumed += (frame.key);
    }
    on mAckSent do (frame: tFrame) {
      assert frame.key in consumed && !(frame.key in ackSent), "ACK represented relay receipt or duplicate consumption";
      ackSent += (frame.key);
      windows[(identity = frame.key.identity, direction = frame.key.direction)] = frame;
      if (frame.final) { finalAck += (frame.key.identity); }
    }
    on mAckApplied do (p: (current: tFrame, source: tFrameKey)) {
      assert p.current.key == p.source && p.source in ackSent && !(p.source in acked),
        "stale ACK changed current directional reservation";
      assert !(p.source.identity in retired) && !(p.source.identity in destroying), "late ACK resurrected retired channel";
      acked += (p.source);
      if (p.current.kind == CallReply) { callAck += ((identity = p.source.identity, call = p.current.call)); }
      if (p.current.kind == ImmediateReply) { immediateAck += (p.source.identity); }
    }
    on mFreed do (frame: tFrame) {
      var address: (identity: tIdentity, direction: tDirection);
      address = (identity = frame.key.identity, direction = frame.key.direction);
      assert frame.key in acked && !frame.final, "frame credit returned before exact consumed ACK";
      assert !(frame.key.identity in retired) && !(frame.key.identity in destroying) && !(frame.key.identity in terminals),
        "final or retired consumption granted another frame";
      assert address in windows && windows[address].key == frame.key, "free targeted a different directional reservation";
      windows -= (address);
    }
    on mCallAdmitted do (p: (identity: tIdentity, call: int)) {
      assert !(p in calls), "original call admitted twice";
      calls[p] = Running; assert held(p.identity) <= 2, "completed replies escaped outstanding invocation bound";
    }
    on mCallSettled do (p: (identity: tIdentity, call: int)) {
      assert p in calls && calls[p] == Running, "call ledger settled more than once or without original slot";
      calls[p] = ReplyReady;
    }
    on mReplyAdmitted do (frame: tFrame) {
      var address: (identity: tIdentity, call: int);
      if (frame.kind == CallReply) {
        address = (identity = frame.key.identity, call = frame.call);
        assert address in calls && calls[address] == ReplyReady, "writer admitted reply outside original ready slot";
        calls[address] = ReplySending;
      } else {
        assert frame.key.identity in immediate, "writer admitted unbounded immediate response";
      }
    }
    on mCallReleased do (p: (identity: tIdentity, call: int)) {
      assert p in callAck && p in calls && calls[p] == ReplySending, "CapDone released slot before original consumed write";
      calls -= (p); callAck -= (p);
    }
    on mImmediateHeld do (frame: tFrame) {
      assert !(frame.key.identity in immediate) && frame.key in delivered && !(frame.key in consumed), "immediate responses bypassed one held input slot";
      immediate[frame.key.identity] = frame.key;
    }
    on mImmediateReleased do (id: tIdentity) {
      assert id in immediate && id in immediateAck, "immediate slot released before original consumed write";
      immediate -= (id); immediateAck -= (id);
    }
    on mTerminalValidated do (frame: tFrame) {
      assert frame.key in delivered && !(frame.key.identity in terminals), "terminal did not hold one original delivered frame";
      terminals += (frame.key.identity);
    }
    on mDestroy do (id: tIdentity) {
      assert !(id in destroying), "resource destruction repeated";
      assert !(id in terminals) || id in finalAck, "terminal destroy preceded final consumption ACK";
      destroying += (id);
    }
    on mSocketClosed do (id: tIdentity) { assert id in destroying, "socket closure lacked original destruction owner"; closed += (id); }
    on mCancelRequested do (id: tIdentity) { }
    on mCancelReturned do (id: tIdentity) {
      assert id in closed, "cancellation deferred behind blocked writer data";
    }
    on mRetired do (id: tIdentity) { retired += (id); }
    on mJoined do (p: (identity: tIdentity, reader: bool)) {
      assert p.identity in closed && p.identity in destroying, "join reported before original socket destruction";
      if (p.reader) { reader += (p.identity); } else { writer += (p.identity); }
    }
    on mNative do (id: tIdentity) { native += (id); }
    on mEnd do (key: tFrameKey) {
      var address: (identity: tIdentity, direction: tDirection);
      address = (identity = key.identity, direction = ToOwner);
      assert key.direction == ToOwner && key.identity in activated, "channel EOF lacked original inbound producer";
      assert !(address in windows) || (windows[address].final && windows[address].key in acked),
        "channel EOF overtook unconsumed original frame";
    }
    on mResources do (id: tIdentity) { resources += (id); }
    on mCleanup do (id: tIdentity) {
      assert id in closed && id in reader && id in writer && id in native && id in resources,
        "safe cleanup inferred from terminal instead of independent resource evidence";
      safeCleanup += (id);
    }
    on mDirectoryDeleted do (id: tIdentity) {
      assert id in safeCleanup, "execution directory deleted on known outcome without safe cleanup";
    }
    on mReport do (id: tIdentity) { assert id in terminals, "report COMMIT fabricated absent terminal"; reports += (id); }
    on mPublished do (id: tIdentity) { assert id in reports, "bounded final published before complete report COMMIT"; }
    on mEntryReleased do (id: tIdentity) {
      assert id in closed && id in reader && id in writer && id in native && id in resources,
        "Launch entry released before independent resource joins and native retirement";
      assert id in live, "Launch entry released twice"; live -= (id);
    }
    on mMetadata do (p: (slot: int, reserve: bool, stream: bool)) {
      assert !p.stream, "channel lifetime borrowed endpoint metadata credit";
      assert p.slot >= 0 && p.slot < 6, "endpoint metadata credit count widened";
      if (p.reserve) { assert !(p.slot in metadata), "endpoint metadata credit reused"; metadata += (p.slot); }
      else { assert p.slot in metadata, "endpoint metadata credit returned twice"; metadata -= (p.slot); }
    }
    on mSnapshot do (p: tView) {
      var id: tIdentity; var address: (identity: tIdentity, direction: tDirection); var actual: int;
      assert p.active == sizeof(live), "Launch capacity inferred from unrelated teardown event";
      if (!(p.identity.id in originals)) { return; }
      id = originals[p.identity.id];
      assert p.calls == held(id) && p.calls <= 2, "CapDone discarded a held original reply slot";
      assert p.immediate == (id in immediate), "immediate slot snapshot lost original input custody";
      address = (identity = id, direction = ToOwner); actual = 0;
      if (address in spent) { actual = spent[address]; }
      assert p.inSpent == actual, "uncertainty refunded original inbound byte admission";
      address.direction = ToSocket; actual = 0;
      if (address in spent) { actual = spent[address]; }
      assert p.outSpent == actual, "uncertainty refunded original outbound byte admission";
    }
  }

  fun held(id: tIdentity): int {
    var entries: seq[(identity: tIdentity, call: int)]; var i: int; var count: int;
    entries = keys(calls);
    while (i < sizeof(entries)) { if (entries[i].identity == id) { count = count + 1; } i = i + 1; }
    return count;
  }
}
