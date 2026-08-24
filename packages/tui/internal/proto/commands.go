package proto

// Command bodies. Field names are snake_case, matching the envelope
// vocabulary the spec freezes (from_seq, reply_to, ...). See protocol.md
// for the normative word on each.

// SubscribeBody scopes a connection to one session. FromSeq zero (or
// absent) asks for a full snapshot; FromSeq > 0 asks the server to
// resume the durable event stream from that seq (snapshot mode
// "resume" followed by a replay) or, if it cannot, to fall back to a
// full snapshot. Exactly one subscribe is accepted per connection.
type SubscribeBody struct {
	Session string `json:"session"`
	FromSeq uint64 `json:"from_seq,omitempty"`
}

// CatchUpBody asks the server to re-deliver the durable events of the
// connection's subscribed session with seq >= FromSeq. Used after the
// client notices a seq gap; reconnect uses subscribe with from_seq
// instead (a fresh connection has no subscribed session yet).
type CatchUpBody struct {
	FromSeq uint64 `json:"from_seq"`
}

// PromptBody starts a run on an idle strand from a user turn.
type PromptBody struct {
	Strand string `json:"strand"`
	Text   string `json:"text"`
}

// SteerBody injects a user turn into a strand's live run (delivered at
// the next checkpoint).
type SteerBody struct {
	Strand string `json:"strand"`
	Text   string `json:"text"`
}

// FollowUpBody queues a user turn to run after the strand's live run
// settles.
type FollowUpBody struct {
	Strand string `json:"strand"`
	Text   string `json:"text"`
}

// AbortBody cancels the live operation on a strand.
type AbortBody struct {
	Strand string `json:"strand"`
}

// ApproveBody approves a pending escalation. Grants must be a subset of
// the escalation's wanted diff (partial approval narrows the
// re-execution); absent means "everything that was wanted".
type ApproveBody struct {
	EscalationID string  `json:"escalation_id"`
	Grants       []Grant `json:"grants,omitempty"`
}

// DenyBody rejects a pending escalation; no re-execution will run.
type DenyBody struct {
	EscalationID string `json:"escalation_id"`
}

// Fork scopes, mirroring the session-layer fork operation.
const (
	ForkScopeBranch = "branch"
	ForkScopeTree   = "tree"
)

// ForkBody forks a strand into a new strand. Scope is "branch" (from
// the strand's leaf) or "tree" (the whole tree view).
type ForkBody struct {
	Strand string `json:"strand"`
	Scope  string `json:"scope"`
	Name   string `json:"name,omitempty"`
}

// NavigateBody moves a strand's leaf to an existing entry.
type NavigateBody struct {
	Strand  string `json:"strand"`
	ToEntry string `json:"to_entry"`
}

// CompactBody requests a manual compaction of a strand.
type CompactBody struct {
	Strand       string `json:"strand"`
	Instructions string `json:"instructions,omitempty"`
}

// CreateStrandBody creates a fresh strand in the session.
type CreateStrandBody struct {
	Name string `json:"name,omitempty"`
}

// SetConfigBody updates session (or, with Strand set, per-strand)
// configuration. Keys are gateway-defined; unknown keys are refused
// with an in-band error, not ignored.
type SetConfigBody struct {
	Strand string         `json:"strand,omitempty"`
	Config map[string]any `json:"config"`
}
