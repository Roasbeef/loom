package proto

import "encoding/json"

// Event bodies. Gateway-defined fields are snake_case; wherever a body
// embeds a value that already has a durable JSON form in the harness
// (entries, messages, usage), that value is carried verbatim in the
// core codec's vocabulary (camelCase, pi field names) so the gateway
// serializes with the codec it already has. See protocol.md.

// Snapshot modes.
const (
	SnapshotFull    = "full"
	SnapshotResume  = "resume"
	SnapshotStrands = "strands"
	SnapshotConfig  = "config"
)

// SnapshotBody answers subscribe/catch_up and acks the strand- and
// config-shaped commands. Which fields are present depends on Mode:
//
//   - "full": everything — the client rebuilds from scratch.
//   - "resume": NextSeq only; the durable events from the requested
//     from_seq are replayed right after, with their original seqs.
//   - "strands": Strands only (fork/create_strand/navigate ack).
//   - "config": Config only (set_config ack).
type SnapshotBody struct {
	Mode    string `json:"mode"`
	Session string `json:"session,omitempty"`
	// NextSeq is the seq the next live event will carry; everything
	// below it is reflected in this snapshot (or in the replay that
	// follows a "resume").
	NextSeq     uint64           `json:"next_seq,omitempty"`
	Strands     []Strand         `json:"strands,omitempty"`
	Entries     []EntryBody      `json:"entries,omitempty"`
	Escalations []EscalationBody `json:"escalations,omitempty"`
	// Usage is the session's running usage total, core codec Usage
	// shape, verbatim.
	Usage  *Usage          `json:"usage,omitempty"`
	Config json.RawMessage `json:"config,omitempty"`
}

// Strand is one strand's summary, as listed in snapshots.
type Strand struct {
	ID   string `json:"id"`
	Name string `json:"name,omitempty"`
	// Leaf is the entry id of the strand's current leaf; empty for a
	// fresh strand.
	Leaf string `json:"leaf,omitempty"`
	// LiveOp is present while an operation is running on this strand.
	LiveOp *LiveOp `json:"live_op,omitempty"`
}

// LiveOp names a running operation and its current display phase.
type LiveOp struct {
	Op    string `json:"op"`
	Phase string `json:"phase"`
}

// EntryBody carries one appended entry. Entry is the core codec entry
// encoding, verbatim and opaque to the envelope; parse it with
// ParseEntry. This event acks prompt/steer/follow_up (the appended user
// entry carries reply_to on the issuing connection).
type EntryBody struct {
	Strand string          `json:"strand"`
	Entry  json.RawMessage `json:"entry"`
}

// Operation display phases the gateway emits. The list is open — the
// phase is a display label (events/bus doctrine: the op.state register
// is the truth) — but these are the ones defined today.
const (
	PhaseStarting        = "starting"
	PhaseAssistant       = "assistant"
	PhaseTools           = "tools"
	PhaseCompacting      = "compacting"
	PhaseAwaitingDefer   = "awaiting_deferred"
	PhaseFailureDrain    = "failure_drain"
	PhaseCancelRequested = "cancel_requested"
	PhaseDone            = "done"
)

// OpTransitionBody reports a durable operation state change. Also the
// ack for abort (phase "cancel_requested") and compact (phase
// "compacting"). Unknown phases must be displayed as-is, never
// rejected.
type OpTransitionBody struct {
	Op     string `json:"op"`
	Strand string `json:"strand"`
	Phase  string `json:"phase"`
}

// Stream delta kinds.
const (
	DeltaText     = "text"
	DeltaThinking = "thinking"
	DeltaToolCall = "tool_call"
)

// StreamDeltaBody is a live streaming fragment. Ephemeral is always
// true: deltas are never persisted, never carry a seq, are never
// replayed by catch_up, and are wholly superseded by the settled entry
// that follows.
type StreamDeltaBody struct {
	Strand    string `json:"strand"`
	Op        string `json:"op"`
	Ephemeral bool   `json:"ephemeral"`
	Kind      string `json:"kind"`
	// Text carries the fragment for "text" and "thinking" deltas.
	Text string `json:"text,omitempty"`
	// CallID/ToolName/ArgumentsFragment carry "tool_call" deltas;
	// ArgumentsFragment is a fragment of the arguments JSON, not
	// necessarily well-formed on its own.
	CallID            string `json:"call_id,omitempty"`
	ToolName          string `json:"tool_name,omitempty"`
	ArgumentsFragment string `json:"arguments_fragment,omitempty"`
}

// UsageBody reports one usage-ledger append. Usage is the core codec
// Usage shape, verbatim. Clients accumulate these on top of the
// snapshot's baseline total.
type UsageBody struct {
	Strand string `json:"strand"`
	Op     string `json:"op,omitempty"`
	Usage  Usage  `json:"usage"`
}

// Escalation statuses, mirroring the broker escalation lifecycle.
const (
	EscalationPending  = "pending"
	EscalationApproved = "approved"
	EscalationRejected = "rejected"
	EscalationConsumed = "consumed"
)

// EscalationBody reports an escalation lifecycle position. Status
// "pending" (with the Denial present) asks the user for a decision;
// "approved"/"rejected" ack the approve/deny commands; "consumed"
// reports the single re-execution was taken.
type EscalationBody struct {
	EscalationID string `json:"escalation_id"`
	Op           string `json:"op"`
	Strand       string `json:"strand"`
	Status       string `json:"status"`
	// Denial is present when Status is "pending" (and in snapshots).
	Denial *Denial `json:"denial,omitempty"`
}

// Strand result statuses.
const (
	ResultDone    = "done"
	ResultAborted = "aborted"
	ResultFailed  = "failed"
)

// StrandResultBody reports a strand's operation settling terminally.
type StrandResultBody struct {
	Strand string   `json:"strand"`
	Op     string   `json:"op"`
	Status string   `json:"status"`
	Error  *OpError `json:"error,omitempty"`
}

// OpError is the terminal error of a failed operation.
type OpError struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

// Error codes the gateway emits. Open set; display unknown codes as-is.
const (
	ErrBadRequest        = "bad_request"
	ErrUnknownSession    = "unknown_session"
	ErrUnknownStrand     = "unknown_strand"
	ErrUnknownEscalation = "unknown_escalation"
	ErrNotPending        = "not_pending"
	ErrConflict          = "conflict"
	ErrUnsupported       = "unsupported"
	ErrInternal          = "internal"
)

// ErrorBody answers a command that failed (reply_to set) or reports a
// connection-scoped fault (reply_to absent).
type ErrorBody struct {
	Code    string          `json:"code"`
	Message string          `json:"message"`
	Details json.RawMessage `json:"details,omitempty"`
}

// Typed body accessors. Each is tolerant of unknown fields (forward
// compatibility) but errors on a missing or malformed body.

func (e Event) Snapshot() (SnapshotBody, error) {
	var b SnapshotBody
	err := decodeBody(EventSnapshot, e.Body, &b)
	return b, err
}

func (e Event) Entry() (EntryBody, error) {
	var b EntryBody
	err := decodeBody(EventEntry, e.Body, &b)
	return b, err
}

func (e Event) OpTransition() (OpTransitionBody, error) {
	var b OpTransitionBody
	err := decodeBody(EventOpTransition, e.Body, &b)
	return b, err
}

func (e Event) StreamDelta() (StreamDeltaBody, error) {
	var b StreamDeltaBody
	err := decodeBody(EventStreamDelta, e.Body, &b)
	return b, err
}

func (e Event) Usage() (UsageBody, error) {
	var b UsageBody
	err := decodeBody(EventUsage, e.Body, &b)
	return b, err
}

func (e Event) Escalation() (EscalationBody, error) {
	var b EscalationBody
	err := decodeBody(EventEscalation, e.Body, &b)
	return b, err
}

func (e Event) StrandResult() (StrandResultBody, error) {
	var b StrandResultBody
	err := decodeBody(EventStrandResult, e.Body, &b)
	return b, err
}

func (e Event) Error() (ErrorBody, error) {
	var b ErrorBody
	err := decodeBody(EventError, e.Body, &b)
	return b, err
}
