// Identity atoms stand for validated original administrative facts. Neither a
// channel incarnation nor an ACK supplies remote service authority by itself.
enum tBinding { LocalBinding, RemoteBinding }
enum tDirection { ToOwner, ToSocket }
enum tPhase { PreparedPaused, Active, Terminating, Closing, Retired }
enum tWindow { PreparedWindow, Available, Reserved, Pending, Finished, WindowRetired }
enum tDisposition { Running, ReplyReady, ReplySending }
enum tFrameKind { CallRequest, ImmediateRequest, TerminalFrame, IgnoredFrame, CallReply, ImmediateReply, MalformedFrame }
enum tAction { Prepare, AcceptCustody, Activate, HistoricalQuery, Reconnect,
  ReserveFrame, DeliverFrame, ChunkAck, HostAdmit, CapDone, AdmitReply,
  SocketConsume, ReceiveAck, DestroyBegin, Cancel, OwnerDeath, RecipientDeath,
  ReaderJoin, WriterJoin, NativeRetire, ReportCommit, PublishFinal,
  MetadataReserve, MetadataRelease, ResourcesRelease, CleanupSafe, DeleteDirectory, EndChannel, Snapshot }
enum tOutcome { Applied, Refused }
enum tMode { StartupCase, ReplyCase, ImmediateCase, StaleCase, IdentityCase,
  TerminalCase, CancelCase, DeathCase, ByteCase, ActiveCase, ReportCase, LocalCase, BoundaryCase, EndCase, RetirementCase }
type tIdentity = (id: int, binding: tBinding, service: int, scope: int,
  generation: int, incarnation: int);
type tFrameKey = (identity: tIdentity, direction: tDirection, sequence: int);
type tCommand = (action: tAction, identity: tIdentity, direction: tDirection,
  sequence: int, payload: int, kind: tFrameKind, call: int);
type tFrame = (key: tFrameKey, wireBytes: int, kind: tFrameKind,
  call: int, delivered: bool, consumed: bool, final: bool);
type tLane = (window: tWindow, sequence: int, spent: int, frame: tFrame);
type tCall = (disposition: tDisposition, settled: bool, sequence: int, wireBytes: int);
type tRow = (identity: tIdentity, phase: tPhase, custody: bool, activated: bool,
  ownerAlive: bool, terminal: bool, terminalAck: bool, destroying: bool,
  socketClosed: bool, readerJoined: bool, writerJoined: bool, nativeRetired: bool,
  reportCommitted: bool, resourcesReleased: bool, cleanupSafe: bool, calls: map[int, tCall], immediate: bool,
  immediateSending: bool, immediateInbound: tFrameKey);
type tView = (outcome: tOutcome, identity: tIdentity, phase: tPhase,
  calls: int, immediate: bool, inWindow: tWindow, outWindow: tWindow,
  inSpent: int, outSpent: int, active: int, dataSlots: int, control: int);
event eCommand: tCommand;
event eView: tView;
event mPrepared: tIdentity;
event mCustody: tIdentity;
event mActivated: tIdentity;
event mHistory: tIdentity;
event mReserved: tFrame;
event mDelivered: tFrame;
event mChunk: tFrameKey;
event mHostConsumed: tFrame;
event mSocketConsumed: tFrame;
event mAckSent: tFrame;
event mAckApplied: (current: tFrame, source: tFrameKey);
event mFreed: tFrame;
event mCallAdmitted: (identity: tIdentity, call: int);
event mCallSettled: (identity: tIdentity, call: int);
event mReplyAdmitted: tFrame;
event mCallReleased: (identity: tIdentity, call: int);
event mImmediateHeld: tFrame;
event mImmediateReleased: tIdentity;
event mTerminalValidated: tFrame;
event mDestroy: tIdentity;
event mSocketClosed: tIdentity;
event mCancelRequested: tIdentity;
event mCancelReturned: tIdentity;
event mRetired: tIdentity;
event mJoined: (identity: tIdentity, reader: bool);
event mNative: tIdentity;
event mReport: tIdentity;
event mPublished: tIdentity;
event mEntryReleased: tIdentity;
event mResources: tIdentity;
event mCleanup: tIdentity;
event mEnd: tFrameKey;
event mDirectoryDeleted: tIdentity;
event mMetadata: (slot: int, reserve: bool, stream: bool);
event mSnapshot: tView;
event mScenarioEnd: tMode;
event mScenarioStart;
event mDecision: (command: tCommand, outcome: tOutcome);

fun payloadLimit(): int { return 16777216; }
fun lifetimeLimit(): int { return 67108864; }
fun chunkLimit(): int { return 65536; }
fun chunkCount(wire: int): int { return (wire + chunkLimit() - 1) / chunkLimit(); }
fun identity(id: int): tIdentity {
  return (id = id, binding = RemoteBinding, service = 100 + id,
    scope = 1, generation = 3, incarnation = 7);
}
