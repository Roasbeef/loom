// Package proto holds the hand-written types for the ClientGateway
// websocket protocol (implementation spec Part 1.6).
//
// The envelope is frozen by the spec: commands are
// {v:1, id, cmd, body} and events are {v:1, reply_to?, event, seq?, body}.
// Body schemas are NOT pinned by the spec; they are defined by this
// package and documented normatively in protocol.md next to this file.
// The Gleam gateway builds to that document and to the golden fixtures
// under testdata/.
//
// Decoding policy: strict on the envelope (v must be 1, the
// discriminator must be present), tolerant on names — an unknown cmd or
// event name is carried as its raw body so an old client survives a new
// server. Unknown fields inside known bodies are ignored for the same
// reason.
package proto

import (
	"encoding/json"
	"fmt"
)

// Version is the protocol version this package speaks. Envelopes with
// any other version are rejected at decode.
const Version = 1

// Command names, frozen by spec Part 1.6.
const (
	CmdPrompt        = "prompt"
	CmdPromptContent = "prompt_content"
	CmdSteer         = "steer"
	CmdFollowUp      = "follow_up"
	CmdAbort         = "abort"
	CmdApprove       = "approve"
	CmdDeny          = "deny"
	CmdFork          = "fork"
	CmdNavigate      = "navigate"
	CmdCompact       = "compact"
	CmdCreateStrand  = "create_strand"
	CmdModels        = "models"
	CmdSetConfig     = "set_config"
	CmdSubscribe     = "subscribe"
	CmdCatchUp       = "catch_up"
)

// Event names, frozen by spec Part 1.6.
const (
	EventSnapshot     = "snapshot"
	EventEntry        = "entry"
	EventOpTransition = "op_transition"
	EventStreamDelta  = "stream_delta"
	EventUsage        = "usage"
	EventEscalation   = "escalation"
	EventStrandResult = "strand_result"
	EventError        = "error"
)

// Command is the client-to-server envelope. ID is client-assigned,
// non-zero, and unique per connection; the server correlates its reply
// via Event.ReplyTo.
type Command struct {
	V    int             `json:"v"`
	ID   uint64          `json:"id"`
	Cmd  string          `json:"cmd"`
	Body json.RawMessage `json:"body,omitempty"`
}

// Event is the server-to-client envelope. Seq is present (non-zero) on
// events that are part of the durable, replayable per-session event
// stream (entry, op_transition, usage, escalation, strand_result);
// snapshot, stream_delta, and error never carry one. ReplyTo is set on
// the copy delivered to the connection whose command it answers.
type Event struct {
	V       int             `json:"v"`
	ReplyTo uint64          `json:"reply_to,omitempty"`
	Event   string          `json:"event"`
	Seq     uint64          `json:"seq,omitempty"`
	Body    json.RawMessage `json:"body,omitempty"`
}

// NewCommand builds a command envelope, marshalling body. A nil body
// produces an envelope with no body field.
func NewCommand(id uint64, cmd string, body any) (Command, error) {
	c := Command{V: Version, ID: id, Cmd: cmd}
	if body != nil {
		raw, err := json.Marshal(body)
		if err != nil {
			return Command{}, fmt.Errorf("proto: marshal %s body: %w", cmd, err)
		}
		c.Body = raw
	}
	return c, nil
}

// DecodeCommand parses a command envelope, strictly: the version must
// be 1 and cmd/id must be present. The cmd name itself is not
// validated — unknown commands are tolerated with their raw body so the
// server can answer them with an in-band error.
func DecodeCommand(data []byte) (Command, error) {
	var c Command
	if err := json.Unmarshal(data, &c); err != nil {
		return Command{}, fmt.Errorf("proto: decode command envelope: %w", err)
	}
	if c.V != Version {
		return Command{}, fmt.Errorf("proto: command version %d, want %d", c.V, Version)
	}
	if c.Cmd == "" {
		return Command{}, fmt.Errorf("proto: command envelope missing cmd")
	}
	if c.ID == 0 {
		return Command{}, fmt.Errorf("proto: command envelope missing id")
	}
	return c, nil
}

// DecodeEvent parses an event envelope, strictly: the version must be 1
// and the event name must be present. The name itself is not validated;
// unknown events keep their raw body (old clients survive new servers).
func DecodeEvent(data []byte) (Event, error) {
	var e Event
	if err := json.Unmarshal(data, &e); err != nil {
		return Event{}, fmt.Errorf("proto: decode event envelope: %w", err)
	}
	if e.V != Version {
		return Event{}, fmt.Errorf("proto: event version %d, want %d", e.V, Version)
	}
	if e.Event == "" {
		return Event{}, fmt.Errorf("proto: event envelope missing event name")
	}
	return e, nil
}

// decodeBody unmarshals an envelope body into dst, treating an absent
// body as an error: every known body in this protocol is an object.
func decodeBody(kind string, raw json.RawMessage, dst any) error {
	if len(raw) == 0 {
		return fmt.Errorf("proto: %s: missing body", kind)
	}
	if err := json.Unmarshal(raw, dst); err != nil {
		return fmt.Errorf("proto: %s body: %w", kind, err)
	}
	return nil
}
