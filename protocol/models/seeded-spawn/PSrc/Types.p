// Shared vocabulary of the seeded spawn model (protocol-change/107, slices 4a to
// 4c).
//
// One parent's spawn of one child whose workspace is a copy of the parent's, from
// the ask to the pull of the child's commits. Four machines take part. The Owner
// is the parent's orchestrator: its stub, its drainer and the single ref it makes
// for the child's commits. The Orch is the receiving orchestrator: `spawn_seed.land`
// with its claim, its delegate session for the child, the Agency's spawn and the
// join. The Exec is the executor that holds the child's workspace, behind a fence
// of an incarnation and a token. Two Wires carry the messages: one between the Owner
// and the Orch, one between the Orch and the Exec. The environment (Chaos) breaks
// connections, restarts any of the three machines, makes an asker give up, and
// delays the bundle.
//
// A state is a tip, an integer. The seed's tip is 1 and the child's work moves its
// tree to 2, so an apply of 1 over a tree at 2 is an older tip over a newer one. A
// capture is a thin bundle of the commits the child made: `desc` is the size its
// description names and `arrived` is the size that arrived.
//
// The transfer of the bundle in pieces is the state transfer model's subject
// (protocol/models/state-transfer), and here it is one `X_SEND` that the executor
// answers stored, no room, or malformed.

enum tKind {
  // Owner to Orch, and back.
  K_SPAWN, K_JOIN,
  R_STARTED, R_ASKAGAIN, R_REFUSED, R_PENDING, R_FINISHED, R_GONE,
  // Orch to Exec, and back.
  X_ATTACH, X_SEND, X_APPLY, X_CAPTURE, X_RELEASE,
  Y_ATTACHED, Y_SENT, Y_APPLIED, Y_STALE, Y_REFUSED, Y_CAPTURED
}

// A message. `pass` echoes the Orch's pass so a reply to an abandoned one is told
// from the current one. `a`, `b` and `c` carry what the kind names.
type tMsg = (kind: tKind, pass: int, a: int, b: int, c: int);

// Why a landing did not finish. The first two and the workspace's refusal are
// about the inputs and are the same on every ask; the rest pass.
enum tWhy { W_SHARED, W_BADSTATE, W_WORKSPACE, W_NOROOM, W_STALE, W_UNREADABLE, W_TIMEOUT }

// The answer to whether the child's session has begun. A record that cannot be
// read is its own answer.
enum tFresh { FR_FRESH, FR_BEGUN, FR_UNREADABLE }

// Where the Orch is in the work of one pass.
enum tPhase { PH_IDLE, PH_ATTACH, PH_SEND, PH_APPLY, PH_JATTACH, PH_CAPTURE }

// Where the spawner places its children.
enum tPlace { PL_DIR, PL_EXEC }

// What a test case plans.
type tPlan = (
  place: tPlace,
  shared: bool,
  badState: bool,
  refuseApply: bool,
  holdLate: bool,
  breaks1: int,
  breaks2: int,
  crashOrch: int,
  crashExec: int,
  crashOwner: int,
  unreadable: int,
  noRoom: int,
  partial: int,
  giveUps: int,
  works: int
);

// --- the wire ---
event eWireEnds: (left: machine, right: machine);
event eL2R: tMsg;
event eR2L: tMsg;
event eInR: tMsg;
event eInL: tMsg;
event eStep;
event eBreak;
event eLinkLost: int;

// --- the environment ---
event eChaosStep;
event ePoke;
event eGiveUp;
event eBundleArrives;
event eChildWork;
event eChildStarted;
event eCrashOrch;
event eCrashExec;
event eCrashOwner;
event eOwnerDone;
event eQuiet;
event eKnowChaos: machine;

// --- the Orch's own steps, each tagged with the incarnation that scheduled it so
// a restart discards what was pending ---
event eSpawnDue: int;
event eReleaseDue: int;
event eChildFinish: int;

// --- what the specs observe ---
event eSpawnAsked;
event eOutcomeSpawned;
event eOutcomeRefused;
event eSessionMade;
event eSessionReleased;
event eTreeSeeded;
event eSeedEffective;
event eFirstTurn;
event eApplied: (before: int, after: int);
event eApplyRepeated;
event eVerdict: tWhy;
event eTransient: tWhy;
event eGate: bool;
event eSettled;
event eRef: (tip: int, arrived: int, desc: int);
event eCrashBetween;
event eJoinLost;
event eCapturedAfterRestart;
