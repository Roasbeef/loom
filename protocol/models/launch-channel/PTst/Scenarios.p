// Every finite script waits for a real channel reply, and checks its outcome.
// Independent monitors require original ownership and recipient event histories.
type tStep = (command: tCommand, outcome: tOutcome);
machine Scenario {
  var channel: machine; var mode: tMode; var steps: seq[tStep]; var index: int;
  start state Init {
    entry (selected: tMode) {
      mode = selected; announce mScenarioStart; channel = new LaunchChannel(this);
      script(); send channel, eCommand, steps[0].command; goto Driving;
    }
  }
  state Driving {
    on eView do (p: tView) {
      assert p.outcome == steps[index].outcome, "scenario did not receive its exact original decision";
      index = index + 1;
      if (index == sizeof(steps)) { announce mScenarioEnd, mode; goto Finished; }
      send channel, eCommand, steps[index].command;
    }
  }
  state Finished { }

  fun add(action: tAction, id: tIdentity, direction: tDirection, sequence: int,
    payload: int, kind: tFrameKind, call: int, outcome: tOutcome) {
    steps += (sizeof(steps), (command = (action = action, identity = id, direction = direction,
      sequence = sequence, payload = payload, kind = kind, call = call), outcome = outcome));
  }
  fun act(action: tAction) { add(action, identity(1), ToOwner, 0, 1, CallRequest, 1, Applied); }
  fun refuse(action: tAction) { add(action, identity(1), ToOwner, 0, 1, CallRequest, 1, Refused); }
  fun bootChannel() { act(Prepare); act(AcceptCustody); act(Activate); }
  fun capDone(call: int, payload: int) { add(CapDone, identity(1), ToOwner, 0, payload, CallRequest, call, Applied); }
  fun frame(direction: tDirection, sequence: int, kind: tFrameKind, call: int, payload: int) {
    if (direction == ToOwner) { add(ReserveFrame, identity(1), direction, 0, payload, kind, call, Applied); }
    else { add(AdmitReply, identity(1), direction, 0, payload, kind, call, Applied); }
    add(DeliverFrame, identity(1), direction, sequence, payload, kind, call, Applied);
  }
  fun consume(action: tAction, direction: tDirection, sequence: int, outcome: tOutcome) {
    add(action, identity(1), direction, sequence, 1, IgnoredFrame, 0, outcome);
  }
  fun incoming(sequence: int, kind: tFrameKind, call: int, payload: int) {
    frame(ToOwner, sequence, kind, call, payload); consume(HostAdmit, ToOwner, sequence, Applied);
    if (kind != ImmediateRequest && kind != TerminalFrame) { consume(ReceiveAck, ToOwner, sequence, Applied); }
  }
  fun outgoing(sequence: int, kind: tFrameKind, call: int, payload: int) {
    frame(ToSocket, sequence, kind, call, payload);
    consume(SocketConsume, ToSocket, sequence, Applied); consume(ReceiveAck, ToSocket, sequence, Applied);
  }

  fun script() {
    var id: tIdentity; var i: int; var payload: int;
    if (mode == StartupCase) {
      act(Prepare); refuse(Activate); refuse(ReserveFrame); refuse(DeliverFrame); act(HistoricalQuery);
      act(AcceptCustody); refuse(AcceptCustody); act(Activate); refuse(Activate);
      incoming(1, IgnoredFrame, 0, 1); refuse(Reconnect); act(HistoricalQuery); return;
    }
    if (mode == LocalCase) {
      id = identity(1); id.binding = LocalBinding; id.service = 101;
      add(Prepare, id, ToOwner, 0, 1, IgnoredFrame, 0, Refused);
      id.service = 0;
      add(Prepare, id, ToOwner, 0, 1, IgnoredFrame, 0, Applied);
      add(AcceptCustody, id, ToOwner, 0, 1, IgnoredFrame, 0, Applied);
      add(Activate, id, ToOwner, 0, 1, IgnoredFrame, 0, Applied);
      add(ReserveFrame, id, ToOwner, 0, 1, IgnoredFrame, 0, Applied);
      add(DeliverFrame, id, ToOwner, 1, 1, IgnoredFrame, 0, Applied);
      add(HostAdmit, id, ToOwner, 1, 1, IgnoredFrame, 0, Applied);
      add(ReceiveAck, id, ToOwner, 1, 1, IgnoredFrame, 0, Applied); return;
    }
    if (mode == ActiveCase) {
      i = 1;
      while (i <= 4) { add(Prepare, identity(i), ToOwner, 0, 1, IgnoredFrame, 0, Applied); i = i + 1; }
      add(Prepare, identity(5), ToOwner, 0, 1, IgnoredFrame, 0, Refused);
      act(Cancel); add(Prepare, identity(5), ToOwner, 0, 1, IgnoredFrame, 0, Refused);
      act(NativeRetire); add(Prepare, identity(5), ToOwner, 0, 1, IgnoredFrame, 0, Refused);
      act(ReaderJoin); add(Prepare, identity(5), ToOwner, 0, 1, IgnoredFrame, 0, Refused);
      act(WriterJoin); add(Prepare, identity(5), ToOwner, 0, 1, IgnoredFrame, 0, Refused);
      act(ResourcesRelease); add(Prepare, identity(5), ToOwner, 0, 1, IgnoredFrame, 0, Applied);
      refuse(Prepare); act(HistoricalQuery); refuse(Activate); return;
    }
    if (mode == DeathCase) {
      act(Prepare); act(OwnerDeath); refuse(AcceptCustody); refuse(Activate); refuse(NativeRetire);
      act(HistoricalQuery); refuse(Reconnect); refuse(Prepare);
      id = identity(2);
      add(Prepare, id, ToOwner, 0, 1, IgnoredFrame, 0, Applied);
      add(AcceptCustody, id, ToOwner, 0, 1, IgnoredFrame, 0, Applied);
      add(Activate, id, ToOwner, 0, 1, IgnoredFrame, 0, Applied);
      add(ReserveFrame, id, ToOwner, 0, 1, IgnoredFrame, 0, Applied);
      add(DeliverFrame, id, ToOwner, 1, 1, IgnoredFrame, 0, Applied);
      add(RecipientDeath, id, ToOwner, 0, 1, IgnoredFrame, 0, Applied);
      add(HostAdmit, id, ToOwner, 1, 1, IgnoredFrame, 0, Refused);
      add(ReceiveAck, id, ToOwner, 1, 1, IgnoredFrame, 0, Refused);
      add(ReaderJoin, id, ToOwner, 0, 1, IgnoredFrame, 0, Applied);
      add(WriterJoin, id, ToOwner, 0, 1, IgnoredFrame, 0, Applied);
      add(NativeRetire, id, ToOwner, 0, 1, IgnoredFrame, 0, Applied);
      add(ResourcesRelease, id, ToOwner, 0, 1, IgnoredFrame, 0, Applied);
      act(HistoricalQuery); return;
    }
    bootChannel();
    if (mode == BoundaryCase) {
      frame(ToOwner, 1, MalformedFrame, 0, 0); consume(HostAdmit, ToOwner, 1, Applied);
      consume(ReceiveAck, ToOwner, 1, Refused); refuse(ReserveFrame);
      id = identity(2);
      add(Prepare, id, ToOwner, 0, 1, IgnoredFrame, 0, Applied);
      add(AcceptCustody, id, ToOwner, 0, 1, IgnoredFrame, 0, Applied);
      add(Activate, id, ToOwner, 0, 1, IgnoredFrame, 0, Applied);
      add(ReserveFrame, id, ToOwner, 0, 1, CallRequest, 1, Applied);
      add(DeliverFrame, id, ToOwner, 1, 1, CallRequest, 1, Applied);
      add(HostAdmit, id, ToOwner, 1, 1, CallRequest, 1, Applied);
      add(ReceiveAck, id, ToOwner, 1, 1, CallRequest, 1, Applied);
      add(CapDone, id, ToOwner, 0, 16777217, CallRequest, 1, Refused);
      add(AdmitReply, id, ToSocket, 0, 1, CallReply, 1, Refused); return;
    }
    if (mode == EndCase) {
      frame(ToOwner, 1, IgnoredFrame, 0, 1);
      consume(EndChannel, ToOwner, 1, Refused); consume(HostAdmit, ToOwner, 1, Applied);
      consume(EndChannel, ToOwner, 1, Refused); act(NativeRetire);
      consume(EndChannel, ToOwner, 1, Refused); consume(ReceiveAck, ToOwner, 1, Applied);
      consume(EndChannel, ToOwner, 1, Applied); refuse(ReserveFrame); refuse(ReportCommit);
      act(DestroyBegin); act(ReaderJoin); act(WriterJoin); act(ResourcesRelease); return;
    }
    if (mode == ReplyCase) {
      incoming(1, CallRequest, 1, 1); incoming(2, CallRequest, 2, 1);
      capDone(1, 1); frame(ToSocket, 1, CallReply, 1, 1); capDone(2, 1);
      frame(ToOwner, 3, CallRequest, 3, 1);
      consume(HostAdmit, ToOwner, 3, Refused);
      add(CapDone, identity(1), ToOwner, 0, 1, CallRequest, 1, Refused);
      add(AdmitReply, identity(1), ToSocket, 0, 1, CallReply, 2, Refused);
      consume(ChunkAck, ToSocket, 1, Applied); consume(ReceiveAck, ToSocket, 1, Refused);
      consume(SocketConsume, ToSocket, 1, Applied); consume(HostAdmit, ToOwner, 3, Refused);
      consume(ReceiveAck, ToSocket, 1, Applied); consume(HostAdmit, ToOwner, 3, Applied);
      consume(ReceiveAck, ToOwner, 3, Applied); capDone(3, 1);
      outgoing(2, CallReply, 2, 1); outgoing(3, CallReply, 3, 1); return;
    }
    if (mode == ImmediateCase) {
      incoming(1, CallRequest, 1, 1); capDone(1, 1); frame(ToSocket, 1, CallReply, 1, 1);
      incoming(2, ImmediateRequest, 0, 1); refuse(ReserveFrame);
      consume(HostAdmit, ToOwner, 2, Refused); consume(ReceiveAck, ToOwner, 2, Refused);
      add(AdmitReply, identity(1), ToSocket, 0, 1, ImmediateReply, 0, Refused);
      consume(SocketConsume, ToSocket, 1, Applied); consume(ReceiveAck, ToSocket, 1, Applied);
      outgoing(2, ImmediateReply, 0, 1); refuse(ReserveFrame);
      consume(ReceiveAck, ToOwner, 2, Applied);
      incoming(3, ImmediateRequest, 0, 1); outgoing(3, ImmediateReply, 0, 1);
      consume(ReceiveAck, ToOwner, 3, Applied); return;
    }
    if (mode == StaleCase || mode == IdentityCase) {
      incoming(1, IgnoredFrame, 0, 1);
      frame(ToOwner, 2, IgnoredFrame, 0, 1); consume(HostAdmit, ToOwner, 2, Applied);
      consume(ReceiveAck, ToOwner, 1, Refused); consume(ChunkAck, ToOwner, 2, Applied);
      consume(ReceiveAck, ToSocket, 2, Refused);
      id = identity(1); id.incarnation = 8;
      add(ReceiveAck, id, ToOwner, 2, 1, IgnoredFrame, 0, Refused);
      id = identity(1); id.generation = 4;
      add(ReceiveAck, id, ToOwner, 2, 1, IgnoredFrame, 0, Refused);
      id = identity(1); id.scope = 2;
      add(ReceiveAck, id, ToOwner, 2, 1, IgnoredFrame, 0, Refused);
      id = identity(1); id.service = 102;
      add(ReceiveAck, id, ToOwner, 2, 1, IgnoredFrame, 0, Refused);
      consume(ReceiveAck, ToOwner, 2, Applied); consume(ReceiveAck, ToOwner, 2, Refused);
      incoming(3, IgnoredFrame, 0, 1); return;
    }
    if (mode == RetirementCase) {
      incoming(1, CallRequest, 1, 1); capDone(1, 1); frame(ToSocket, 1, CallReply, 1, 1);
      consume(SocketConsume, ToSocket, 1, Applied); act(Cancel);
      consume(ReceiveAck, ToSocket, 1, Refused); refuse(ReserveFrame); refuse(ReportCommit);
      act(NativeRetire); act(ReaderJoin); act(WriterJoin); act(ResourcesRelease);
      consume(ReceiveAck, ToSocket, 1, Refused); return;
    }
    if (mode == CancelCase) {
      add(MetadataReserve, identity(1), ToOwner, 0, 1, IgnoredFrame, 0, Refused);
      i = 0;
      while (i < 6) { add(MetadataReserve, identity(1), ToOwner, 0, 0, IgnoredFrame, i, Applied); i = i + 1; }
      add(MetadataReserve, identity(1), ToOwner, 0, 1, IgnoredFrame, 0, Refused);
      incoming(1, CallRequest, 1, 1); capDone(1, 1); frame(ToSocket, 1, CallReply, 1, 1);
      act(Cancel); consume(SocketConsume, ToSocket, 1, Refused); consume(ReceiveAck, ToSocket, 1, Refused);
      refuse(Activate); refuse(Reconnect); act(HistoricalQuery); act(NativeRetire); act(ReaderJoin); act(WriterJoin); act(ResourcesRelease);
      i = 0;
      while (i < 6) { add(MetadataRelease, identity(1), ToOwner, 0, 0, IgnoredFrame, i, Applied); i = i + 1; }
      return;
    }
    if (mode == TerminalCase || mode == ReportCase) {
      if (mode == TerminalCase) {
        incoming(1, CallRequest, 1, 1); capDone(1, 1); frame(ToSocket, 1, CallReply, 1, 1);
        consume(SocketConsume, ToSocket, 1, Applied);
        incoming(2, TerminalFrame, 0, 1); consume(ReceiveAck, ToSocket, 1, Refused);
      } else { refuse(ReportCommit); incoming(1, TerminalFrame, 0, 1); refuse(PublishFinal); act(ReportCommit); act(PublishFinal); refuse(DeleteDirectory); }
      if (mode == TerminalCase && $) {
        act(Cancel); consume(ReceiveAck, ToOwner, 2, Refused);
      } else {
        if (mode == TerminalCase) { consume(ReceiveAck, ToOwner, 2, Applied); }
        else { consume(ReceiveAck, ToOwner, 1, Applied); }
        refuse(ReserveFrame); act(DestroyBegin);
      }
      act(NativeRetire); if (mode == TerminalCase) { refuse(PublishFinal); }
      act(ReaderJoin); act(WriterJoin); refuse(CleanupSafe); refuse(DeleteDirectory);
      act(ResourcesRelease); act(CleanupSafe); act(DeleteDirectory);
      if (mode == TerminalCase) { refuse(PublishFinal); act(ReportCommit); act(PublishFinal); }
      refuse(ReportCommit);
      refuse(Activate); refuse(Reconnect); act(HistoricalQuery); return;
    }
    if (mode == ByteCase) {
      i = 1;
      while (i <= 4) {
        payload = payloadLimit(); if (i == 4) { payload = 16777200; }
        incoming(i, CallRequest, i, payload); capDone(i, payload); outgoing(i, CallReply, i, payload);
        i = i + 1;
      }
      add(ReserveFrame, identity(1), ToOwner, 0, 1, TerminalFrame, 0, Refused);
      refuse(ReserveFrame); act(Cancel); act(HistoricalQuery);
      id = identity(2);
      add(Prepare, id, ToOwner, 0, 1, IgnoredFrame, 0, Applied);
      add(AcceptCustody, id, ToOwner, 0, 1, IgnoredFrame, 0, Applied);
      add(Activate, id, ToOwner, 0, 1, IgnoredFrame, 0, Applied);
      add(ReserveFrame, id, ToOwner, 0, 16777217, IgnoredFrame, 0, Refused);
      add(ReserveFrame, id, ToOwner, 0, 1, IgnoredFrame, 0, Refused); return;
    }
  }
}
