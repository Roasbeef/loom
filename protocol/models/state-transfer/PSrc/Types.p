// Shared vocabulary of the state transfer model (protocol-change/107, "Send").
//
// A state is a bundle of `size` pieces. The model sends one element per piece,
// so an offset is an index and "the bytes held" is the length of a sequence. The
// honest bundle is a sequence of ones, and a forged one has a zero among them,
// which is how a hash mismatch is told: the receiver holds the described state's
// content (`expected`) and compares the whole of what it received with it when
// the last piece lands, as `state_store.finish` compares the SHA-256.
//
// Two machines take part. The Sender stands for `state_transfer.transfer` and
// the drainer that calls it again: a pass asks where the receiver stands, sends
// the piece at that offset, and continues at the offset each verdict reports. The
// Receiver stands for `state_transfer.take` and `stage` over a store: a durable
// half-written file, and a durable record once the whole bundle matches. A Wire
// between them carries every message, loses all of them when the connection
// breaks, and delivers the two directions in any interleaving. The environment
// (Chaos) breaks the connection, restarts either end, and makes a pass give up
// early while its request is still in flight.
//
// The receiver's restart may leave its half-written file shorter than it was:
// a rename is not a flush, so after a crash the file can be short. The record of
// a finished state is taken as durable once the receiver has answered that it
// holds the whole of it. In the code that record is written with the same atomic
// rename and `get` verifies it again on every read, so a record lost to a crash is
// a state that is absent and is sent again; the model does not lose it, because
// what it checks is that nothing wrong is ever named by a record, not that every
// record survives.

// What a request to the receiver asks.
enum tAsk { ASK_STATUS, ASK_PIECE }

// What the receiver answers. `A_PARTIAL` and `A_COMPLETE` answer a status
// question, and the rest answer a piece.
enum tAnswer { A_PARTIAL, A_COMPLETE, A_ACCEPTED, A_OUT_OF_ORDER, A_MISMATCH }

// A request on the wire. `attempt` is the sender's pass, which the reply echoes
// so that a reply to an abandoned pass is told from the current one: in the code
// every exchange has a subject of its own and a late reply lands in nobody's
// mailbox.
type tRequest = (attempt: int, ask: tAsk, offset: int, payload: int);

// A reply on the wire. `held` is the bytes the receiver holds.
type tReply = (attempt: int, answer: tAnswer, held: int);

// What a test case plans.
type tPlan = (size: int, forged: bool, breaks: int, receiverCrashes: int, senderCrashes: int, giveUps: int);

// --- the wire ---
event eWireEnds: (sender: machine, receiver: machine);
event eSendUp: tRequest;
event eSendDown: tReply;
event eNetUp: tRequest;
event eNetDown: tReply;
event eStep;
event eBreak;
event eNoConn;

// --- the environment ---
event eChaosStep;
event ePoke;
event eGiveUp;
event eCrashSender;
event eCrashReceiver;

// --- what the specs observe ---
// A pass began. The transfer is owed an end from here.
event eBegan;

// The sender concluded that the receiver holds the state.
event eDelivered;

// The sender was told, finally, that the bundle is not the one described.
event eDeclined;

// A record now names a state, with the content it holds and the content the
// description names.
event eStored: (held: seq[int], expected: seq[int]);

// The half-written file changed, with what the description names.
event ePart: (held: seq[int], expected: seq[int]);

// The sender's first piece of a pass was not at offset zero: it resumed.
event eResumed: int;

// A crash left a non-empty half-written file shorter than it was.
event eTruncated;

// A piece the receiver already held was accepted again.
event eDuplicated;

// The sender followed a correction of its offset.
event eResynced;
