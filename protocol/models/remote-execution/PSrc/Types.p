// Logical identity survives reconnect and reboot. Digest is deliberately
// outside the map key: the same identity with changed content conflicts.
type tKey = (session: int, workspace: int, operation: int, execution: int, executor: int,
             sessionEpoch: int, workspaceEpoch: int);
type tRequest = (key: tKey, digest: int);
type tEpoch = (session: int, workspace: int);
enum tPhase { Admitted, Intent, Running, Terminal }
enum tOutcome { NoOutcome, Succeeded, Cancelled }
type tRow = (request: tRequest, phase: tPhase, launchBoot: int,
             retired: bool, receipt: bool, outcome: tOutcome, terminalDigest: int);
enum tAnswer { Prior, Conflict, Fenced, Capacity, Missing }
type tReply = (request: tRequest, answer: tAnswer, row: tRow,
               connection: int, boot: int);
type tWire = (owner: machine, request: tRequest, connection: int);
type tNative = (key: tKey, boot: int);
type tCancelEffect = (asked: tNative, active: tNative);
enum tMode { Reliable, Lossy, CrashBeforeStart, CrashAfterSend, TerminalCommitPaused }
enum tWitness { Success, Uncertain, Reuse, Pressure, ClosedReconcile, OldFence,
                Advance, ConflictSeen, LostTransport, ReceiptLost, CancelLost, AdmissionLost, AdmissionAckLost, ResultLost }
type tSetup = (driver: machine, mode: tMode);

// Wire messages may be dropped at the sending boundary. A drop never emits
// a definite refusal or native retirement. Driver control is out of band.
event ePrepare: tRequest;
event eRetry: tRequest;
event eOwnerReconcile: tRequest;
event eOwnerCancel: tRequest;
event eOwnerReceipt: tRequest;
event eReconnect;
event eOwnerCrash;
event eAdmit: tWire;
event eReconcile: tWire;
event eCancel: tWire;
event eReceipt: tWire;
event eReply: tReply;
event eView: tReply;

// Launch intent and native start are separate turns, with a boot fence on
// the volatile permission. Helper events name their logical execution.
event eLaunch: tNative;
event eStartNative: tNative;
event eStartedNative: tNative;
event eFinishNative;
event eRetireNative;
event eTerminalNative: (native: tNative, outcome: tOutcome);
event eRetiredNative: tNative;
event eCancelNative: tNative;
event eDeliverCancel;
event eInspectNative;
event eCrash;
event eCloseEpoch;
event eCollect: tKey;
event eAdvanceEpoch;
event eControlDone;
event eConnect: (owner: machine, helper: machine);
event eHelperConnect: machine;
event eDriverConnect: (owner: machine, executor: machine, helper: machine);
event eTick;

// Monitor events describe facts at the actual transition, not a driver's
// expectation. Durable means an atomic, surviving abstract store commit.
event mScenarioBegin;
event mScenarioEnd;
event mCustody: tRequest;
event mAdmit: tRequest;
event mAck: tRequest;
event mIntent: tNative;
event mStart: tNative;
event mTerminal: tKey;
event mRetired: tKey;
event mOwnerStored: tRequest;
event mReceipt: tRequest;
event mGC: tKey;
event mClose: tEpoch;
event mAdvance: tEpoch;
event mCancelEffect: tCancelEffect;
event mAnswer: tReply;
event mRecovered: (boot: int, rows: map[tKey, tRow]);
event mWitness: tWitness;

fun request(id: int, sessionEpoch: int, workspaceEpoch: int): tRequest {
  return (key = (session = 1, workspace = 1, operation = id, execution = id, executor = 1,
                 sessionEpoch = sessionEpoch, workspaceEpoch = workspaceEpoch), digest = 1);
}

fun rowSafe(row: tRow): bool {
  return row.phase == Terminal && row.retired && row.receipt;
}

enum tWithheld { ReceiptPending, RetirementPending }

// Native payload retention and reducer commit are separate durable decisions.
// Digests 1, 3 and 2 denote Prepared, native terminal and outer result classes.
type tTerminalPayload = (request: tRequest, native: tNative, digest: int, outcome: tOutcome);
event eCommitNativeTerminal: tNative;
event eNativePayloadView: tTerminalPayload;
event mNativePayloadRetained: tTerminalPayload;
event mNativeTerminalCommitted: tTerminalPayload;
