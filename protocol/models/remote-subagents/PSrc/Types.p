// Shared vocabulary of the remote subagents model (protocol-change/084).
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
enum tKind { K_SPAWN, K_SPAWNED, K_REFUSED, K_JOIN, K_JOINED, K_RUN_ENDED }

// A child's state in the delegate session. CS_SETTLED is the child's run
// ending on its own, CS_STOPPED is a stop the remote decided (the deadline, or
// a run end), and CS_LOST is a child whose run died with the remote's VM.
enum tChildState { CS_RUNNING, CS_SETTLED, CS_STOPPED, CS_LOST }

// The state of a stub on the laptop (`remote_child.State`).
enum tStubState { ST_REQUESTED, ST_SPAWNED, ST_SETTLED, ST_REFUSED }

// `run` is the parent run the call site belongs to. `owner` is that run when the
// child is attached to it (so a run end stops it) and -1 when the child is
// detached, which is every child in phase 1.
type tMsg = (kind: tKind, src: machine, dest: machine, site: tSite, child: tChild, st: tChildState, run: int, owner: int);

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
event eNet: tMsg;
event eStep;
event eBreak;
event eCrashRemote;
event eNoConn;
event eWirePort: machine;

// Laptop.
event eBegin: tPlanSite;
event eStubAnswer: (site: tSite, child: tChild);
event eStubRefusal: tSite;
event eDrain;
event eAbort;

// Port.
event eRestart;
event eDeadlineAll;
event eTick;
event eFinishOne;

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

event eWatch: machine;
event eUnwatch: machine;
