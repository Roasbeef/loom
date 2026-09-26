// Shared vocabulary of the terminal attachment and mutation model.
//
// The model has four kinds of process: the Terminal (reducer plus runtime),
// an AttachmentWorker per replacement attempt, a Socket per connection
// (the websocket transport and the daemon's gateway handler for that
// connection), and the environment (Operator, Deadline, Fuse). Everything
// the terminal reads arrives in an inbox the terminal created and names by
// an integer, which stands for a terminal-owned `Subject`.

// ---------------------------------------------------------------------------
// Wire frames.
// ---------------------------------------------------------------------------

// A request the terminal writes. SUBSCRIBE and CATCH_UP begin a credited
// transfer (session_channel.start_recorded, capture_again), SNAPSHOT_NEXT
// grants one response (session_channel.credit), MUTATION and READ are
// commands admitted through session_channel.submit.
enum tReqKind { SUBSCRIBE, CATCH_UP, SNAPSHOT_NEXT, MUTATION, READ }

// `cmd` is the operator command a MUTATION carries, or -1.
type tReq = (kind: tReqKind, id: int, cmd: int);

// What a socket delivers to its inbox (connection.Message). BEGIN and END
// (M_BEGIN, M_END) stand for snapshot_begin and snapshot_end with the chunks elided,
// MUT_REPLY and READ_REPLY for correlated replies, COMMITTED for a pushed
// commit notice. NETWORK_FAULT and CLOSED are the transport's own loss
// notices.
enum tMsgKind { M_BEGIN, M_END, M_MUT_REPLY, M_READ_REPLY, M_COMMITTED, M_NETWORK_FAULT, M_CLOSED }

// `replyTo` is the correlated request id (0 for a push); `at` is the
// session's next_seq for END and the committed sequence for COMMITTED.
type tMsg = (kind: tMsgKind, replyTo: int, at: int);

// ---------------------------------------------------------------------------
// Transport events.
// ---------------------------------------------------------------------------

// A socket delivers one message to the inbox it was connected with. `sock`
// is the sender; the terminal routes only by `inbox`, and the specs use
// `sock` to name the frame's origin.
type tFramePayload = (inbox: int, sock: machine, msg: tMsg);
event eFrame: tFramePayload;

// session_channel.Transmit, performed by session_channel.perform.
type tWritePayload = (sock: machine, req: tReq);
event eWrite: tWritePayload;

// A close the terminal performs: session_channel.Shut, attachment.CloseStray,
// or the close inside attachment.cancel.
type tSockPayload = (sock: machine);
event eShut: tSockPayload;

// The worker's own close when its acknowledgement wait times out
// (attachment.start_recorded, the Error(Nil) arm).
event eWorkerClose: tSockPayload;

// The socket guardian killing a socket whose startup worker exited
// abnormally (host/websocket start_owned_socket, AttemptGone).
event eGuardianKill: tSockPayload;

// The daemon side of a socket serves its oldest pending request.
event eServe;

// The environment breaks a socket from the daemon or network side.
event eFuse;

// ---------------------------------------------------------------------------
// Attachment worker events.
// ---------------------------------------------------------------------------

// attachment.Prepared, sent to the attempt's terminal-owned prepared inbox.
type tPreparedPayload = (inbox: int, attempt: int, sock: machine, worker: machine);
event ePrepared: tPreparedPayload;

// The weft relay's outcome for the attempt, sent to the outcomes inbox.
// `completed` is weft.AllDelivered after a normal return; false stands for
// Failed, Crashed, Abandoned and the other failure variants.
type tOutcomePayload = (inbox: int, attempt: int, completed: bool);
event eOutcome: tOutcomePayload;

// attachment.Acknowledge, the reply that releases the waiting worker.
type tAttemptPayload = (attempt: int);
event eAck: tAttemptPayload;

// weft.cancel on the attempt's cancel signal.
event eCancel: tAttemptPayload;

// The attempt's 90 s deadline (weft.deadline plus the acknowledgement wait).
event eDeadline;
event eStep;

// ---------------------------------------------------------------------------
// Operator and clock inputs, and the terminal's own scheduling events.
// ---------------------------------------------------------------------------

// /sessions selection or reattach: session_control.begin_open.
event eOpOpen;

// Enter on a composed mutation: outbound.send_frame then session_channel.submit.
event eOpSubmit;

// Escape: interaction.update_ready_key then inbound.cancel_pending.
event eOpEscape;

// Ctrl-C: submit.quit.
event eOpQuit;

// A tick after the 250 ms idle refresh fell due (session_channel.tick, Ready).
event eClockRefresh;

// A tick after a request deadline passed (session_channel.tick, in flight).
event eClockDeadline;

// The runtime's wakeup after traffic arrived (tick.update_tick).
event eTick;

// The runtime performs what the step returned (runtime.perform).
event ePerform;

// The operator's next action.
event eNextAction;

// ---------------------------------------------------------------------------
// Announcements observed by the specs.
// ---------------------------------------------------------------------------

// A mutation's local disposition (session_channel.Disposition) and its
// later resolution. ACKED is session_channel.Acknowledged and UNKNOWN is
// session_channel.UnknownOutcome.
enum tDisp { WAITING, SENT, NOT_SENT, ACKED, UNKNOWN }
type tCmdPayload = (cmd: int, sock: machine, disp: tDisp);
event eCmdAdmitted: tCmdPayload;
event eCmdResolved: tCmdPayload;

// Why a lane moved to Closed: session_channel.fail, session_channel.retire,
// or session_channel.close at quit.
enum tLoss { LOST_FAIL, LOST_RETIRE, LOST_QUIT }
type tLanePayload = (sock: machine, why: tLoss);
event eLaneClosed: tLanePayload;

// The candidate channel produced its first Captured update.
type tAttemptSockPayload = (attempt: int, sock: machine);
event eCandidateCaptured: tAttemptSockPayload;

// attachment.Failed reached interaction.candidate_outcome.
event eCandidateFailed: tAttemptPayload;

// attachment.Adopted reached interaction.candidate_outcome and the model
// swapped its channel and inbox.
event eVisible: tAttemptSockPayload;

// One inbox message was reduced into the visible lane
// (inbound.handle_connection_message). `source` is the socket that sent it.
type tAppliedPayload = (source: machine);
event eApplied: tAppliedPayload;

// submit.quit ran.
event eQuit;

// Worker and socket lifetimes, for the custody specs.
event eWorkerStarted: tAttemptPayload;
event eWorkerEnded: tAttemptPayload;
type tSockAttemptPayload = (sock: machine, attempt: int);
event eSocketOpened: tSockAttemptPayload;
event eSocketDown: tSockPayload;

// The daemon applied a mutation it received.
type tAppliedCmdPayload = (cmd: int, sock: machine);
event eDaemonApplied: tAppliedCmdPayload;
