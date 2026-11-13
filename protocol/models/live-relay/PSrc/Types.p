// Types, events and constants of the live session relay model
// (protocol-change/108-live-session-relay.md). The model is abstract: it knows
// frames, pieces, polls, a lease and a bound, and nothing about the 105
// envelope or the wire encoding.

// What a command frame from the lane is. The feed host's filter maps each kind
// to one treatment: forwarded, judged through the relayed door, or refused.
enum tCmd { CMD_FORWARD, CMD_APPROVE, CMD_FORBID }

// How a feed ended. EN_NONE means it is live. EN_DETACHED is the laptop's own
// detach, which the proposal does not name as an answer; the model gives it the
// same keep-then-forget treatment as the other endings.
enum tEnded { EN_NONE, EN_LAPSED, EN_STOPPED, EN_REVOKED, EN_DETACHED }

enum tFrameKind { FK_REPLY, FK_PUSH }
enum tReqKind { RQ_POLL, RQ_SEND, RQ_DETACH }
enum tAnsKind { AN_POLL, AN_SEND, AN_DETACH, AN_REFUSED }

// The two ways a decision can reach the hub.
enum tDoor { DOOR_RELAYED, DOOR_LOCAL }

// A frame as the gateway or the feed host writes it, before the queue numbers it.
// `gid` identifies it for the specs. Gateway frames have gids from 1. Frames the
// feed host answers itself (a forbidden reply, a decision reply) have gids from
// 1001. `req` is the lane frame a reply answers.
type tSink = (gid: int, size: int, fk: tFrameKind, req: int);

// A frame in the feed host's queue, numbered from 1 per feed.
type tFrame = (n: int, gid: int, size: int, fk: tFrameKind, req: int);

// A request the laptop sends to the box: a poll, one piece of a lane frame, or a
// detach. `after` is the number of the last frame the laptop received. `n`,
// `offset` and `total` place a piece (offset counts from 0).
type tReq = (kind: tReqKind, pollId: int, after: int, wait: int, n: int, offset: int, total: int, cmd: tCmd);

// The box's answer. `ended` is EN_NONE while the feed is live. An AN_REFUSED
// answer stands for a refusal: `feed_ended` when `ended` names an ending, and a
// refused piece when it is EN_NONE.
type tAns = (kind: tAnsKind, pollId: int, frames: seq[tFrame], ended: tEnded, n: int, offset: int);

// A lane frame, completed on the box and handed to the gateway.
type tGwFrame = (n: int, cmd: tCmd, pieces: int, total: int);

// A lane frame handed from the lane to ui_feed for sending in pieces.
type tOut = (n: int, cmd: tCmd, total: int);

type tLaneCmd = (cmd: tCmd, pieces: int);

// Constants, in logical ticks and frames. The proposal's 15 s lease, 5 s wait and
// 512 frame bound are scaled down so the state space stays small; the relations
// between them are what the properties depend on. A poll is held for less than
// the lease, and a poll or piece that has no answer is repeated sooner than the
// lease ends.
fun Lease(): int { return 10; }
fun Wait(): int { return 2; }
fun PollTimeout(): int { return 3; }
fun SendTimeout(): int { return 3; }
fun MaxFrames(): int { return 3; }
fun MaxBytes(): int { return 4; }

// The most feeds one spawner holds, scaled down from the proposal's eight to one,
// which is enough to show the rule and keeps the state space small. A feed
// holds a place from its reservation until its process exits, which is when an
// ended feed is forgotten one lease after it ended, or when the page detaches.
fun Cap(): int { return 1; }

// The directory that counts places: a feed asks it for one, and says when it is
// gone.
event eReserve: machine;
event eReserved;
event eCapRefused;
event eFeedGone;
// The feed process exited, announced for the specs.
event eFeedExited;

// Wiring.
event eGwWire: machine;
event eLinkWire: (host: machine, ui: machine);
event eUiWire: machine;

// The clock. Every machine acknowledges a tick or a flush to the sender.
event eTick: machine;
event eFlush: machine;
event eAck;

// The environment.
event eEmit: int;
event eStopSession;
event eRevoke;
event eLocalApprove: machine;
event eLaneCmd: tLaneCmd;
event eOpen;
event eClose;
event eBreak;
event eHeal;

// The gateway and the feed host, in the box's process.
event eSink: tSink;
event eEndFeed: tEnded;
event eGwDetach;
event eGwFrame: tGwFrame;
event eRelayedDecide: (src: machine, n: int);
event eHubDone: int;

// The link, in both directions.
event eToBox: tReq;
event eToLaptop: tAns;
event eReq: tReq;
event eAns: tAns;

// The laptop.
event eLaneSubmit: tOut;
event eDeliver: tFrame;
event eUiEnded: tEnded;

// Observations for the specs.
event eWritten: int;
event eFeedStarted: machine;
event eFeedEnded: tEnded;
event eLapse: int;
event eAdmitted: (gid: int, size: int);
event eAnswerSent: (count: int, hostEnded: int);
event eDelivered: (gid: int, endAnswer: int);
event eGapObserved;
event eGwReceived: (n: int, pieces: int, total: int, cmd: tCmd);
event eDecided: (door: tDoor, caller: machine);
event eLaneTx: int;
event eLaneFailed;
event eShortPartition;
event eSuperseded;
event eRepeatPiece;
event eForgotten;
event eRefusedForgotten;
event eLinkDropped;
event eGwDetached;
event eAttachRefused;
// A poll whose `after` is ahead of the queue (0) or behind what was acknowledged (1).
event eCursorRefused: int;
