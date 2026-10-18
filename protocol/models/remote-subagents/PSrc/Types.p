// Shared vocabulary of the remote subagents model (protocol-change/084).
//
// Phase 2 adds the other direction: a child on the remote mails its parent. The
// mail is a row in the delegate session's outbox, sent by the remote's drainer
// over a connection the laptop made and keeps up, and answered by the laptop
// with a receipt. The remote never dials, so the Wire has a connection that a
// break takes down and a reconnection puts back, and the model assumes that the
// reconnection is fair: a connection that breaks is eventually up again (the
// link keeper's liveness assumption).
//
// Four kinds of process take part. The parent's side is one Laptop, which
// stands for the parent session's store (the `remote-child/{site digest}`
// stubs), its Agency and its remote drainer, and one SpawnCall per call site,
// which stands for the effect process that `agent_spawn` runs. The remote side
// is one Port, which stands for `loom_orchestrator` together with the delegate
// session's Agency holder and the durable records it keeps. A Wire between
// them carries every message that crosses the network, and the environment
// (Chaos) breaks it.
//
// A call site is an integer. The child name a site derives is a function of the
// site (`nameOf`). The model forces two sites to derive one name so that the
// `minted_by` comparison of the adoption check has something to refuse.
// The tool run of a child is not modelled beyond its state.

type tSite = int;
type tChild = int;

// What the Port's message handler is told. `K_RUN_ENDED` is built on the remote
// and has no sender on the laptop in phase 1 (design note, section 8.3), so only
// the cases that name a run end send it, with Chaos as the modelled sender.
//
// `K_MAIL` is a child's mail, sent by the remote to the laptop, and `K_MAILED` is
// the laptop's answer. `code` of an answer is one of the `MAIL_*` values below.
enum tKind { K_SPAWN, K_SPAWNED, K_REFUSED, K_JOIN, K_JOINED, K_RUN_ENDED, K_RELEASE, K_RELEASED, K_MAIL, K_MAILED }

// What the laptop answers a mail with. `MAIL_DELIVERED` and `MAIL_DECLINED` are
// receipts: the parent was steered, or had no run open and the refusal is the
// receipt. `MAIL_UNKNOWN` says no stub names the child, and `MAIL_NOT_OPEN` says
// the parent session is not resident. Only the last is worth asking again.
enum tMailCode { MAIL_DELIVERED, MAIL_DECLINED, MAIL_UNKNOWN, MAIL_NOT_OPEN }

// Whether the remote holds a delegate session for the parent. `SS_NONE` is no
// row at all, `SS_OPEN` is a session that serves spawns, and `SS_RELEASING` is a
// session whose `Release` was handled: the released fence is written, every
// child is stopped, and the registry deletes the session once its slot drains.
// Deleting the session removes its children, its fences and everything else
// stored under it, and the next `Spawn` for the parent makes a new session.
enum tSession { SS_NONE, SS_OPEN, SS_RELEASING }

// A child's state in the delegate session. CS_SETTLED is the child's run
// ending on its own, CS_STOPPED is a stop the remote decided (the deadline, or
// a run end), and CS_LOST is a child whose run died with the remote's VM.
enum tChildState { CS_RUNNING, CS_SETTLED, CS_STOPPED, CS_LOST }

// The state of a stub on the laptop (`remote_child.State`).
enum tStubState { ST_REQUESTED, ST_SPAWNED, ST_SETTLED, ST_REFUSED }

// `run` is the parent run the call site belongs to. `owner` is that run when the
// child is attached to it (so a run end stops it) and -1 when the child is
// detached, which is every child in phase 1. `id` is a mail's identity, the
// child's call-site digest on the remote, and `code` is the answer to a mail.
type tMsg = (kind: tKind, src: machine, dest: machine, site: tSite, child: tChild, st: tChildState, run: int, owner: int, id: int, code: tMailCode);

// A row of the delegate session's outbox: the child that sent the mail, by the
// call site that minted it, and whether the laptop has answered.
type tRow = (site: tSite, child: tChild, answered: bool);

type tSubmit = (sender: machine, msg: tMsg);

// A child record in the delegate session. `minted_by` is the call site.
type tChildRec = (mintedBy: tSite, run: int, owner: int, st: tChildState, overdue: bool);

// A stub: the state and, once the remote answered, the child it names.
type tStub = (st: tStubState, child: tChild, run: int, owner: int);

// A call site a case starts: the parent run it belongs to and its owner.
type tPlanSite = (site: tSite, run: int, owner: int);

// The name the remote derives from a call site. Sites 0 and 2 collide.
fun nameOf(site: tSite): int {
  return site % 2;
}

// Wire.
event eSend: tSubmit;

// A message the remote originates. The remote does not dial: it is sent only
// while the connection is up, and is not sent at all when it is down.
event eSendUp: tSubmit;
event eNet: tMsg;
event eStep;
event eBreak;
event eCrashRemote;
event eNoConn;

// The link keeper (or a dial from the laptop) brings the connection back.
event eReconnect;
event eWirePort: machine;

// Laptop.
event eDelete;
event eBegin: tPlanSite;
event eStubAnswer: (site: tSite, child: tChild);
event eStubRefusal: tSite;
event eDrain;
event eAbort;

// The parent session closes and opens again, and the parent's run ends.
event eParentClose;
event eParentOpen;
event eParentRunEnds;

// Port.
event eSlotDrained;
event eRestart;
event eDeadlineAll;
event eTick;
event eFinishOne;

// A child sends its parent a message, and the remote's drainer takes a pass.
event eUpward;
event eMailPass;
event eLaptop: machine;

// Chaos.
event eChaosStep;
event eRunEnd: int;

// Announcements, observed by the specs only.
event eStubRequested: tSite;
event eStubDone: tSite;
event eStubSpawnedAs: (site: tSite, child: tChild);
event eCreated: (site: tSite, child: tChild, run: int, owner: int);
event eAnswered: (site: tSite, child: tChild);
event eChildTerminal: (child: tChild, st: tChildState);
event eReported: (site: tSite, child: tChild, st: tChildState);
event eRefused: (site: tSite, reason: int);
event eRunEndedHandled: (run: int, stillRunning: int);

// A `Release` was handled in the session of generation `gen`: `stopped` children
// were stopped by it and `stillRunning` were left running. A generation is one
// delegate session, from the message that made it to its deletion.
event eReleaseHandled: (gen: int, stopped: int, stillRunning: int);
event eSessionMade: tKind;
event eChildIn: (child: tChild, gen: int);
event eSessionDeleted;
event eReleaseWritten;
event eReleaseTold;
event eReleaseNoSession;

// A row is written in the outbox, and settled by an answer or by the deletion
// of the session that held it.
event eMailQueued: int;
event eMailSettled: int;

// The parent was steered by a mail, once per delivery. `eRunClosed` is the
// parent's run ending.
event eSteered: int;
event eRunClosed;

// The laptop answered `MAIL_UNKNOWN` for a child, and whether it holds a stub
// for that child in any state.
event eUnknownAnswered: (site: tSite, hasStub: bool);
event eMailForRequested;
event eMailNotOpen;
event eMailRepeated;
event eMailDeclined;

event eWatch: machine;
event eUnwatch: machine;
