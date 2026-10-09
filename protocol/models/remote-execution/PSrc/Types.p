// Shared vocabulary of the remote tool execution model.
//
// Three kinds of process take part. The executor side is one Host, which
// stands for host.gleam together with the durable ledger of
// storage/exec_ledger.gleam. The orchestrator side is an Orch, which stands
// for one session and its owner, and a Call per effect process, which stands
// for surface.gleam's run and recover. A Wire between them carries every
// message that crosses the network, and the environment (Chaos) breaks it.
//
// A call key is an integer. The tool body is not modelled beyond the moment it
// starts (the `eStart` announcement) and the moment it ends (a Body process
// tells the Host), and its result is a number derived from the key so that a
// delivered result can be compared with the one the ledger stored.

type tKey = int;

// Whether the planner may replay a call whose fate is unknown to the runtime
// (operation.ReplaySafe and ReplayNever). It decides how `recover` asks.
enum tReplay { REPLAY_SAFE, REPLAY_NEVER }

// A ledger row's state (exec_ledger.CallState). A missing row is the absence of
// an entry. `ack` turns a settled row into a tombstone, ROW_ACKED, which keeps
// the key taken for the rest of the scope's incarnation (the model has one) and
// holds no outcome.
enum tRow { ROW_ADMITTED, ROW_TERMINAL, ROW_UNKNOWN, ROW_ACKED }

// A `Run`'s reply (protocol.RunAnswer). The two refusals the model can reach
// are named: an attach token that is not the scope's (`StaleToken`) and a
// scope with no plane in this VM (`NoPlane`).
enum tAnswer { ANS_FINISHED, ANS_LOST, ANS_STALE, ANS_NOPLANE }

// A `Query` or `QueryOrFence` reply (protocol.Lookup).
enum tLook { LOOK_MISSING, LOOK_ADMITTED, LOOK_TERMINAL, LOOK_UNKNOWN, LOOK_FENCED }

// What the orchestrator stages for the model to read once a call settles.
// D_NOT_RUN is the sentence "the call never reached the executor and did not
// run"; D_LOST is the unknown-outcome sentence; D_STALE and D_NOPLANE are the
// text of a refusal (surface.run turns RunRefused into ToolFailed).
enum tDelivery { D_FINISHED, D_LOST, D_NOT_RUN, D_STALE, D_NOPLANE }

// The message kinds that cross the wire (protocol.HostMessage and its replies).
// K_CALL_DOWN is not a message in the code: it is the host's monitor of an
// effect process firing, and it is carried like one because the monitor's
// signal travels the same wire.
enum tKind { K_ATTACH, K_ATTACHED, K_RUN, K_ANSWER, K_ASK, K_LOOKUP, K_ACK, K_CALL_DOWN, K_START, K_STOP, K_LIST, K_LISTED, K_CALL_LOST }

// The background executions (protocol-change/078, the addendum on background
// code mode) add five kinds. K_START is `StartExecution`, admitted by key as a
// `Run` is and answered with a K_ANSWER. K_STOP is `StopExecution`, which has
// no reply. K_LIST and K_LISTED are the reconciler's `ListUnacked` and its
// answer, which carries the executions still running and the settled execution
// rows. K_CALL_LOST is, like K_CALL_DOWN, a monitor firing rather than a
// message: the waiter's node went away, so the DOWN's reason is `noconnection`.
// An execution's key is an integer like a call's; the executions use keys from
// `firstExecution()` up, so the two never share one.

// Whether an effect process starts a fresh call or recovers an orphaned one.
enum tMode { MODE_RUN, MODE_RECOVER }

// When the orchestrator's acknowledgement reaches the wire. In the code an
// acknowledgement is sent by the reconciler (owner_port.gleam), one period after
// a result was staged and not before, and the period (a minute) is far longer
// than a message stays in flight. ACK_AFTER_QUIET stands for that: the wire holds
// the acknowledgement until every message already in flight has been delivered
// or lost. ACK_AT_ONCE sends it when the result is staged, to show what the
// ledger relies on that assumption for (README.md, "Defects found").
enum tAck { ACK_AFTER_QUIET, ACK_AT_ONCE }

// One ledger row.
type tRowRec = (phase: tRow, outcome: int);

// One message on the wire. `from` is the process a reply goes back to (or, for
// K_CALL_DOWN, the process that died). `fence` selects QueryOrFence over Query
// in a K_ASK. `attempt` numbers the sender's exchanges (each has its own reply
// subject) and a reply carries the attempt it answers; `resent` marks a send
// repeated after a dropped connection, so the probes can tell it from a first send.
type tMsg = (kind: tKind, dest: machine, from: machine, key: tKey, token: int, attempt: int, resent: bool, fence: bool, answer: tAnswer, look: tLook, outcome: int, running: seq[tKey], settled: seq[tKey]);

// One process waiting on a live run, and the attempt whose reply subject it
// waits on. Each attempt of a request has a reply subject of its own
// (`process.new_subject()` in surface.send_and_wait), so a reply to an attempt
// the sender has given up on is never mistaken for the answer to a later one.
type tWaiter = (proc: machine, attempt: int);

// A run that is going now: the job that runs it and the processes waiting on it.
type tLive = (job: int, waiters: seq[tWaiter]);

// A message handed to the wire together with the process that sent it, which
// is what the wire's per-pair ordering is keyed on.
type tSubmit = (sender: machine, msg: tMsg);

// The outcome the fence stores (`protocol.did_not_run_text` as a ToolFailed).
fun fenceOutcome(): int {
  return -1;
}

// The result the tool body produces for a key.
fun bodyOutcome(key: tKey): int {
  return 100 + key;
}

// The first key an execution uses. Calls use the keys below it.
fun firstExecution(): int {
  return 10;
}

fun isExecution(key: tKey): bool {
  return key >= firstExecution();
}

// ---------------------------------------------------------------------------
// Wire events.
// ---------------------------------------------------------------------------

// A process hands a message to the wire; the wire later hands it to `to`.
event eSend: tSubmit;
event eLazySend: tSubmit;
event eNet: tMsg;

// The wire's own scheduling step, and the environment's two attacks on it.
event eStep;
event eBreak;
event eCrashHost;

// The connection dropped: a monitor on the other side fired with
// `noconnection`. The host also hears it for every waiter it holds.
event eNoConn;

// The executor's VM restarted. It reaches the host in the wire's own order, so
// everything the wire delivered earlier was handled by the old VM and
// everything delivered later is handled by the new one.
event eCrash;

// Tells the wire which host to notify.
event eWireHost: machine;

// ---------------------------------------------------------------------------
// Host and orchestrator events.
// ---------------------------------------------------------------------------

// The tool body ended (weft.Completed, relayed to the host).
event eBodyDone: (key: tKey, job: int);

// An effect process settled its call.
event eCallDone: (gen: int, key: tKey, kind: tDelivery, outcome: int);

// The environment kills the session's open or its runtime.
event eOpenCrash;
event eRuntimeRestart;
event eChaosStep;

// ---------------------------------------------------------------------------
// Announcements the specs observe.
// ---------------------------------------------------------------------------

// The orchestrator made a call's intent durable.
event eIntent: tKey;

// The host started the tool body for a key, with the token of the Run that
// caused it and the token the scope held when it was admitted.
event eStart: (key: tKey, runToken: int, scopeToken: int);

// The ledger stored the fence for a key, or the surface reported a
// ReplayNever key as not started.
event eFenced: tKey;
event eReportedNotStarted: tKey;

// The ledger stored a terminal outcome, marked a key unknown, or deleted a row.
event eTerminal: (key: tKey, outcome: int);
event eUnknown: tKey;
event eAcked: tKey;

// The orchestrator staged a call's outcome for the model.
event eDelivered: (key: tKey, kind: tDelivery, outcome: int);

// The host cancelled a live run because its last waiter went away, and whether
// that waiter's exit reason was `noconnection`.
event eCancelled: (key: tKey, noconn: bool);

// --- background executions --------------------------------------------------

// The orchestrator's open attached under this token, or ended. The execution
// service (Record) launches and recovers on the first and loses its worker on
// the second.
event eOpenReady: int;
event eOpenGone;

// A worker heard how its execution's start ended.
event eExecDone: (gen: int, key: tKey, answer: tAnswer, outcome: int);

// The environment cancels one live execution (an owner's cancel or an abort of
// the launching operation), lets every live execution's deadline pass, or runs
// the reconciler's last pass once the network is quiet.
event eExecCancel;
event eDeadline;
event eReconcile;

// The execution service made an execution's record: the launch was claimed.
event eExecCreated: tKey;

// The record closed: finished with the value the worker heard or recovery
// read, or lost. `decided` is true for a loss the service chose (a cancel, the
// deadline, a restart) and false for a loss an answer from the executor caused.
event eRecordFinished: (key: tKey, outcome: int);
event eRecordLost: (key: tKey, decided: bool);

// The service decided an execution must stop, and the host processed a stop.
event eStopDecided: tKey;
event eStopProcessed: tKey;

// The service acknowledged a settled execution row.
event eExecAckSent: tKey;

// A start found its key barred by a stop that arrived first.
event eBarredStart: tKey;

// Recovery finished a record from the value the executor had stored.
event eExecRecovered: tKey;

// Events that mark a situation the probes ask the checker to reach.
event eStaleRun: tKey;
event eJoined: (key: tKey, resent: bool);
event eFoundFence: tKey;
event eStoredAnswer: (key: tKey, resent: bool);
