// Probes retain effect histories and exact returned decisions. Reaching the
// driver's last index alone establishes none of these ownership observations.
spec ChannelReachability observes mPrepared, mCustody, mActivated, mReserved,
  mHostConsumed, mSocketConsumed, mAckSent, mFreed, mCallSettled, mCallReleased,
  mImmediateHeld, mImmediateReleased, mTerminalValidated, mDestroy,
  mCancelRequested, mCancelReturned, mJoined, mNative, mResources, mCleanup,
  mDirectoryDeleted, mReport, mPublished, mEntryReleased, mMetadata,
  mDecision, mScenarioEnd, mHistory, mRetired, mEnd {
  var prepared: int; var custody: int; var activated: int; var host: int;
  var socket: int; var freed: int; var settled: int; var released: int;
  var heldImmediate: int; var releasedImmediate: int; var terminal: int;
  var finalAck: int; var destroyed: int; var cancelReturned: int; var joined: int;
  var native: int; var resources: int; var safeCleanupCount: int; var deleted: int;
  var report: int; var published: int; var entries: int; var history: int;
  var retired: int; var refused: int; var early: int; var stale: int;
  var foreign: int; var streamRefused: int; var maxFrame: int; var ends: int;
  var byteIn: int; var byteOut: int; var metadata: set[int];
  var outboundHeld: set[tIdentity]; var stalledSettlement: bool;
  var independentCancel: bool; var local: bool; var malformed: bool;
  start state Watching {
    on mPrepared do (id: tIdentity) { prepared = prepared + 1; if (id.binding == LocalBinding && id.service == 0) { local = true; } }
    on mCustody do (id: tIdentity) { custody = custody + 1; }
    on mActivated do (id: tIdentity) { activated = activated + 1; }
    on mReserved do (f: tFrame) {
      if (f.key.identity.id == 1) {
        if (f.key.direction == ToOwner) { byteIn = byteIn + f.wireBytes; }
        else { byteOut = byteOut + f.wireBytes; outboundHeld += (f.key.identity); }
      }
      if (f.wireBytes == 16777220) { maxFrame = maxFrame + 1; }
      if (f.wireBytes == 4 && f.kind == MalformedFrame) { malformed = true; }
    }
    on mHostConsumed do (f: tFrame) { host = host + 1; }
    on mSocketConsumed do (f: tFrame) { socket = socket + 1; }
    on mAckSent do (f: tFrame) { if (f.final) { finalAck = finalAck + 1; } }
    on mFreed do (f: tFrame) { freed = freed + 1; if (f.key.direction == ToSocket) { outboundHeld -= (f.key.identity); } }
    on mCallSettled do (p: (identity: tIdentity, call: int)) { settled = settled + 1; if (p.identity in outboundHeld) { stalledSettlement = true; } }
    on mCallReleased do (p: (identity: tIdentity, call: int)) { released = released + 1; }
    on mImmediateHeld do (f: tFrame) { heldImmediate = heldImmediate + 1; }
    on mImmediateReleased do (id: tIdentity) { releasedImmediate = releasedImmediate + 1; }
    on mTerminalValidated do (f: tFrame) { terminal = terminal + 1; }
    on mDestroy do (id: tIdentity) { destroyed = destroyed + 1; }
    on mCancelRequested do (id: tIdentity) { if (id in outboundHeld && sizeof(metadata) == 6) { independentCancel = true; } }
    on mCancelReturned do (id: tIdentity) { cancelReturned = cancelReturned + 1; }
    on mJoined do (p: (identity: tIdentity, reader: bool)) { joined = joined + 1; }
    on mNative do (id: tIdentity) { native = native + 1; }
    on mResources do (id: tIdentity) { resources = resources + 1; }
    on mCleanup do (id: tIdentity) { safeCleanupCount = safeCleanupCount + 1; }
    on mDirectoryDeleted do (id: tIdentity) { deleted = deleted + 1; }
    on mReport do (id: tIdentity) { report = report + 1; }
    on mPublished do (id: tIdentity) { published = published + 1; }
    on mEntryReleased do (id: tIdentity) { entries = entries + 1; }
    on mHistory do (id: tIdentity) { history = history + 1; }
    on mRetired do (id: tIdentity) { retired = retired + 1; }
    on mEnd do (key: tFrameKey) { ends = ends + 1; }
    on mMetadata do (p: (slot: int, reserve: bool, stream: bool)) { if (p.reserve) { metadata += (p.slot); } else { metadata -= (p.slot); } }
    on mDecision do (p: (command: tCommand, outcome: tOutcome)) {
      if (p.outcome == Refused) {
        refused = refused + 1;
        if (activated == 0 && (p.command.action == Activate || p.command.action == ReserveFrame || p.command.action == DeliverFrame)) { early = early + 1; }
        if (p.command.action == ReceiveAck) { stale = stale + 1; if (p.command.identity != identity(1)) { foreign = foreign + 1; } }
        if (p.command.action == MetadataReserve && p.command.payload != 0) { streamRefused = streamRefused + 1; }
      }
    }
    on mScenarioEnd do (mode: tMode) {
      if (mode == StartupCase) {
        assert prepared == 1 && custody == 1 && activated == 1 && host == 1 && freed == 1 && early >= 3 && history == 2, "missing startup history";
        assert false, "witness: custody preceded single activation and historical read never recreated delivery";
      }
      if (mode == ReplyCase) {
        assert settled == 3 && released == 3 && socket == 3 && host == 3 && stalledSettlement && refused >= 4, "missing stalled reply history";
        assert false, "witness: stalled writer retained running ready sending slots until exact consumption";
      }
      if (mode == ImmediateCase) {
        assert heldImmediate == 2 && releasedImmediate == 2 && socket == 3 && host == 3 && freed == 6 && released == 1 && refused >= 5, "missing immediate history";
        assert false, "witness: immediate input withheld ACK while earlier writer consumption remained runnable";
      }
      if (mode == StaleCase || mode == IdentityCase) {
        assert host == 3 && freed == 3 && stale >= 7 && foreign == 4, "missing reused window and foreign ACK history";
        assert false, "witness: stale direction scope generation incarnation and service ACKs preserved genuine reservation";
      }
      if (mode == TerminalCase) {
        assert terminal == 1 && finalAck == 1 && destroyed == 1 && joined == 2 && native == 1 && resources == 1 && report == 1 && published == 1 && entries == 1 && safeCleanupCount == 1 && deleted == 1, "missing terminal teardown history";
        assert false, "witness: validated final ACK preceded destroy join and never granted another frame";
      }
      if (mode == RetirementCase) {
        assert host == 1 && socket == 1 && settled == 1 && released == 0 && freed == 1 && cancelReturned == 1 && destroyed == 1 && joined == 2 && native == 1 && resources == 1 && entries == 1 && refused >= 4, "missing actual consumption before cancellation history";
        assert false, "witness: cancellation retired consumed but unacknowledged original writer without resurrection";
      }
      if (mode == CancelCase) {
        assert independentCancel && cancelReturned == 1 && destroyed == 1 && joined == 2 && native == 1 && entries == 1 && streamRefused == 2, "missing independent cancellation history";
        assert false, "witness: independent cancellation closed stalled writer with every endpoint metadata credit occupied";
      }
      if (mode == DeathCase) {
        assert prepared == 2 && retired == 2 && cancelReturned == 1 && entries == 1 && native == 1 && joined == 2 && activated == 1 && history == 2 && refused >= 7, "missing original death history";
        assert false, "witness: original owner death retained uncertainty while exact recipient cleanup released only sibling";
      }
      if (mode == ByteCase) {
        assert byteIn == lifetimeLimit() && byteOut == lifetimeLimit() && maxFrame == 6 && host == 4 && socket == 4 && retired >= 2 && refused >= 4, "missing exact wire-byte exhaustion history";
        assert false, "witness: both directions reached exact lifetime bytes and first excess retired without refund";
      }
      if (mode == ActiveCase) {
        assert prepared == 5 && destroyed == 1 && native == 1 && joined == 2 && entries == 1 && refused >= 6 && history == 1, "missing bounded active owner history";
        assert false, "witness: four unresolved Launch entries refused fifth until original close joins and native proof";
      }
      if (mode == ReportCase) {
        assert terminal == 1 && finalAck == 1 && native == 1 && joined == 2 && entries == 1 && report == 1 && published == 1 && safeCleanupCount == 1 && deleted == 1 && refused >= 6, "missing report and independent cleanup history";
        assert false, "witness: known report never authorized directory deletion before independent safe cleanup";
      }
      if (mode == LocalCase) {
        assert local && prepared == 1 && custody == 1 && activated == 1 && host == 1 && freed == 1 && refused == 1, "missing local identity history";
        assert false, "witness: local incarnation did not fabricate remote Launch authority";
      }
      if (mode == BoundaryCase) {
        assert malformed && host == 1 && retired == 2 && settled == 0 && socket == 0 && refused >= 4, "missing malformed and excessive reply histories";
        assert false, "witness: semantic malformed frame and excessive completed reply retired without silent drop";
      }
      if (mode == EndCase) {
        assert host == 1 && ends == 1 && freed == 1 && native == 1 && entries == 1 && refused >= 5, "missing ordered inbound EOF history";
        assert false, "witness: single inbound producer EOF followed exact frame consumption and never replaced native proof";
      }
    }
  }
}

// This is completion of the finite scripted workload under checker scheduling.
// It is not a transport fairness or unbounded physical liveness theorem.
spec DirectedCompletion observes mScenarioStart, mScenarioEnd {
  start cold state Waiting { on mScenarioStart goto Driving; }
  hot state Driving { on mScenarioEnd goto Finished; }
  cold state Finished { }
}
