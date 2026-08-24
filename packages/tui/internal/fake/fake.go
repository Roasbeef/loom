// Package fake is a gateway that speaks the protocol in
// internal/proto/protocol.md, backed by in-memory session state. It
// exists so the TUI and the connection client can be built and tested
// today, before the Gleam gateway lands: tests script it directly, and
// the --demo mode of loom-tui runs against it in-process.
//
// It implements the parts of the contract clients depend on precisely:
// snapshot on subscribe, resume-with-replay by seq, catch_up, per-cmd
// replies with reply_to, escalation lifecycle, and in-band errors.
package fake

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"sync"

	"github.com/coder/websocket"

	"github.com/roasbeef/loom/tui/internal/proto"
)

// Server serves any number of sessions over /v1/ws.
type Server struct {
	mu       sync.Mutex
	sessions map[string]*Session
	token    string
}

// NewServer builds an empty server. token, when non-empty, is required
// as a bearer token on every upgrade.
func NewServer(token string) *Server {
	return &Server{sessions: make(map[string]*Session), token: token}
}

// AddSession registers a session and returns it for scripting.
func (s *Server) AddSession(id string) *Session {
	sess := &Session{id: id, nextSeq: 1, conns: make(map[*conn]struct{})}
	s.mu.Lock()
	s.sessions[id] = sess
	s.mu.Unlock()
	return sess
}

// Session returns a registered session, or nil.
func (s *Server) Session(id string) *Session {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.sessions[id]
}

// Handler is the websocket endpoint; mount it at /v1/ws.
func (s *Server) Handler() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if s.token != "" && r.Header.Get("Authorization") != "Bearer "+s.token {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		ws, err := websocket.Accept(w, r, nil)
		if err != nil {
			return
		}
		c := &conn{ws: ws, server: s}
		c.serve(r.Context())
	})
}

// A loggedEvent is one durable event: replayable, seq-stamped.
type loggedEvent struct {
	seq   uint64
	event string
	body  json.RawMessage
}

// OnCommand is a scripting hook: it sees every command after the
// built-in bookkeeping ran, so scripts can drive multi-event flows
// (streaming, escalations) in response to client commands.
type OnCommand func(sess *Session, cmd proto.Command)

// Session is one scripted session: strand list, durable event log,
// escalation states, and the live connections.
type Session struct {
	id string

	mu          sync.Mutex
	strands     []proto.Strand
	entries     []proto.EntryBody // recent-entry window for snapshots
	log         []loggedEvent
	nextSeq     uint64
	usage       proto.Usage
	escalations map[string]*escalationState
	conns       map[*conn]struct{}
	onCommand   OnCommand
}

type escalationState struct {
	body proto.EscalationBody
}

// SetOnCommand installs the scripting hook.
func (sess *Session) SetOnCommand(fn OnCommand) {
	sess.mu.Lock()
	sess.onCommand = fn
	sess.mu.Unlock()
}

// SetStrands replaces the strand list.
func (sess *Session) SetStrands(strands ...proto.Strand) {
	sess.mu.Lock()
	sess.strands = strands
	sess.mu.Unlock()
}

// Strands returns a copy of the strand list.
func (sess *Session) Strands() []proto.Strand {
	sess.mu.Lock()
	defer sess.mu.Unlock()
	out := make([]proto.Strand, len(sess.strands))
	copy(out, sess.strands)
	return out
}

// SetPhase updates a strand's live-op display phase in the strand list
// ("" clears the live op) without emitting an event.
func (sess *Session) SetPhase(strand, op, phase string) {
	sess.mu.Lock()
	defer sess.mu.Unlock()
	for i := range sess.strands {
		if sess.strands[i].ID == strand {
			if phase == "" {
				sess.strands[i].LiveOp = nil
			} else {
				sess.strands[i].LiveOp = &proto.LiveOp{Op: op, Phase: phase}
			}
		}
	}
}

// DropConns closes every live connection abruptly (mid-stream drop for
// reconnect tests).
func (sess *Session) DropConns() {
	sess.mu.Lock()
	conns := make([]*conn, 0, len(sess.conns))
	for c := range sess.conns {
		conns = append(conns, c)
	}
	sess.mu.Unlock()
	for _, c := range conns {
		c.ws.CloseNow()
	}
}

// broadcastLocked stamps a durable event with the next seq, appends it
// to the log, and fans it out; replyConn (when non-nil) gets the copy
// with reply_to set. Callers hold sess.mu.
func (sess *Session) broadcastLocked(event string, body any, replyConn *conn, replyTo uint64) uint64 {
	raw, err := json.Marshal(body)
	if err != nil {
		panic(fmt.Sprintf("fake: marshal %s: %v", event, err))
	}
	seq := sess.nextSeq
	sess.nextSeq++
	sess.log = append(sess.log, loggedEvent{seq: seq, event: event, body: raw})
	for c := range sess.conns {
		ev := proto.Event{V: proto.Version, Event: event, Seq: seq, Body: raw}
		if c == replyConn {
			ev.ReplyTo = replyTo
		}
		c.send(ev)
	}
	return seq
}

// Broadcast emits one durable event scripted from outside a command
// (no reply correlation).
func (sess *Session) Broadcast(event string, body any) uint64 {
	sess.mu.Lock()
	defer sess.mu.Unlock()
	return sess.broadcastLocked(event, body, nil, 0)
}

// Ephemeral fans out a non-durable event (stream_delta): no seq, no
// log, lost on disconnect — exactly the contract.
func (sess *Session) Ephemeral(body proto.StreamDeltaBody) {
	body.Ephemeral = true
	raw, err := json.Marshal(body)
	if err != nil {
		panic(fmt.Sprintf("fake: marshal delta: %v", err))
	}
	sess.mu.Lock()
	defer sess.mu.Unlock()
	for c := range sess.conns {
		c.send(proto.Event{V: proto.Version, Event: proto.EventStreamDelta, Body: raw})
	}
}

// AppendEntry stamps and broadcasts an entry event, tracking it in the
// snapshot window.
func (sess *Session) AppendEntry(strand string, entry json.RawMessage) uint64 {
	sess.mu.Lock()
	defer sess.mu.Unlock()
	return sess.appendEntryLocked(strand, entry, nil, 0)
}

func (sess *Session) appendEntryLocked(strand string, entry json.RawMessage, replyConn *conn, replyTo uint64) uint64 {
	body := proto.EntryBody{Strand: strand, Entry: entry}
	sess.entries = append(sess.entries, body)
	for i := range sess.strands {
		if sess.strands[i].ID == strand {
			var parsed struct {
				ID string `json:"id"`
			}
			if err := json.Unmarshal(entry, &parsed); err == nil {
				sess.strands[i].Leaf = parsed.ID
			}
		}
	}
	return sess.broadcastLocked(proto.EventEntry, body, replyConn, replyTo)
}

// AddUsage accumulates and broadcasts a usage event.
func (sess *Session) AddUsage(strand, op string, usage proto.Usage) uint64 {
	sess.mu.Lock()
	defer sess.mu.Unlock()
	sess.usage.Add(usage)
	return sess.broadcastLocked(proto.EventUsage, proto.UsageBody{Strand: strand, Op: op, Usage: usage}, nil, 0)
}

// RaiseEscalation broadcasts a pending escalation and tracks it for
// approve/deny.
func (sess *Session) RaiseEscalation(body proto.EscalationBody) uint64 {
	body.Status = proto.EscalationPending
	sess.mu.Lock()
	defer sess.mu.Unlock()
	if sess.escalations == nil {
		sess.escalations = make(map[string]*escalationState)
	}
	sess.escalations[body.EscalationID] = &escalationState{body: body}
	return sess.broadcastLocked(proto.EventEscalation, body, nil, 0)
}

// snapshotLocked builds a full snapshot body.
func (sess *Session) snapshotLocked() proto.SnapshotBody {
	strands := make([]proto.Strand, len(sess.strands))
	copy(strands, sess.strands)
	entries := make([]proto.EntryBody, len(sess.entries))
	copy(entries, sess.entries)
	var escalations []proto.EscalationBody
	for _, st := range sess.escalations {
		if st.body.Status == proto.EscalationPending {
			escalations = append(escalations, st.body)
		}
	}
	usage := sess.usage
	return proto.SnapshotBody{
		Mode:        proto.SnapshotFull,
		Session:     sess.id,
		NextSeq:     sess.nextSeq,
		Strands:     strands,
		Entries:     entries,
		Escalations: escalations,
		Usage:       &usage,
	}
}

// conn is one live websocket connection.
type conn struct {
	ws     *websocket.Conn
	server *Server

	mu      sync.Mutex
	session *Session
	sendCh  chan proto.Event
	ctx     context.Context
}

// serve pumps one connection: a writer goroutine drains sendCh while
// this goroutine reads commands. On read error it cancels the writer and
// joins it before unregistering from the session, so no send racing the
// close ever reaches a socket that already stopped writing.
func (c *conn) serve(ctx context.Context) {
	defer c.ws.CloseNow()
	c.ctx = ctx
	c.sendCh = make(chan proto.Event, 512)
	writeDone := make(chan struct{})
	writeCtx, cancel := context.WithCancel(ctx)
	defer cancel()
	go func() {
		defer close(writeDone)
		for {
			select {
			case ev := <-c.sendCh:
				data, err := json.Marshal(ev)
				if err != nil {
					continue
				}
				if err := c.ws.Write(writeCtx, websocket.MessageText, data); err != nil {
					return
				}
			case <-writeCtx.Done():
				return
			}
		}
	}()
	defer func() {
		if sess := c.currentSession(); sess != nil {
			sess.mu.Lock()
			delete(sess.conns, c)
			sess.mu.Unlock()
		}
	}()
	for {
		_, data, err := c.ws.Read(ctx)
		if err != nil {
			cancel()
			<-writeDone
			return
		}
		c.handle(data)
	}
}

func (c *conn) currentSession() *Session {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.session
}

// send queues an event; a slow consumer drops the connection rather
// than blocking the session.
func (c *conn) send(ev proto.Event) {
	select {
	case c.sendCh <- ev:
	default:
		c.ws.CloseNow()
	}
}

func (c *conn) sendError(replyTo uint64, code, message string) {
	raw, _ := json.Marshal(proto.ErrorBody{Code: code, Message: message})
	c.send(proto.Event{V: proto.Version, ReplyTo: replyTo, Event: proto.EventError, Body: raw})
}

func (c *conn) sendReply(replyTo uint64, event string, body any) {
	raw, err := json.Marshal(body)
	if err != nil {
		c.sendError(replyTo, proto.ErrInternal, err.Error())
		return
	}
	c.send(proto.Event{V: proto.Version, ReplyTo: replyTo, Event: event, Body: raw})
}

func (c *conn) handle(data []byte) {
	cmd, err := proto.DecodeCommand(data)
	if err != nil {
		c.sendError(0, proto.ErrBadRequest, err.Error())
		return
	}
	switch cmd.Cmd {
	case proto.CmdSubscribe:
		c.handleSubscribe(cmd)
	case proto.CmdCatchUp:
		c.handleCatchUp(cmd)
	default:
		sess := c.currentSession()
		if sess == nil {
			c.sendError(cmd.ID, proto.ErrBadRequest, "subscribe first")
			return
		}
		c.handleSessionCommand(sess, cmd)
	}
}

func (c *conn) handleSubscribe(cmd proto.Command) {
	var body proto.SubscribeBody
	if err := json.Unmarshal(cmd.Body, &body); err != nil {
		c.sendError(cmd.ID, proto.ErrBadRequest, err.Error())
		return
	}
	if c.currentSession() != nil {
		c.sendError(cmd.ID, proto.ErrConflict, "already subscribed")
		return
	}
	c.server.mu.Lock()
	sess := c.server.sessions[body.Session]
	c.server.mu.Unlock()
	if sess == nil {
		c.sendError(cmd.ID, proto.ErrUnknownSession, "no session "+body.Session)
		return
	}
	c.mu.Lock()
	c.session = sess
	c.mu.Unlock()

	sess.mu.Lock()
	defer sess.mu.Unlock()
	sess.conns[c] = struct{}{}
	if body.FromSeq == 0 {
		c.sendReply(cmd.ID, proto.EventSnapshot, sess.snapshotLocked())
		return
	}
	c.resumeLocked(sess, cmd.ID, body.FromSeq)
}

func (c *conn) handleCatchUp(cmd proto.Command) {
	sess := c.currentSession()
	if sess == nil {
		c.sendError(cmd.ID, proto.ErrBadRequest, "subscribe first")
		return
	}
	var body proto.CatchUpBody
	if err := json.Unmarshal(cmd.Body, &body); err != nil {
		c.sendError(cmd.ID, proto.ErrBadRequest, err.Error())
		return
	}
	sess.mu.Lock()
	defer sess.mu.Unlock()
	c.resumeLocked(sess, cmd.ID, body.FromSeq)
}

// resumeLocked answers with snapshot{mode:resume} and replays the
// durable log from fromSeq with original seqs. The fake never forgets
// its log, so the full-snapshot fallback only triggers for a from_seq
// beyond the stream.
func (c *conn) resumeLocked(sess *Session, replyTo uint64, fromSeq uint64) {
	if fromSeq > sess.nextSeq {
		c.sendReply(replyTo, proto.EventSnapshot, sess.snapshotLocked())
		return
	}
	c.sendReply(replyTo, proto.EventSnapshot, proto.SnapshotBody{
		Mode: proto.SnapshotResume, NextSeq: sess.nextSeq,
	})
	for _, logged := range sess.log {
		if logged.seq >= fromSeq {
			c.send(proto.Event{V: proto.Version, Event: logged.event, Seq: logged.seq, Body: logged.body})
		}
	}
}

func (c *conn) handleSessionCommand(sess *Session, cmd proto.Command) {
	sess.mu.Lock()
	hook := sess.onCommand
	handled := c.applyCommandLocked(sess, cmd)
	sess.mu.Unlock()
	if !handled {
		return
	}
	if hook != nil {
		hook(sess, cmd)
	}
}

// applyCommandLocked performs the built-in bookkeeping and reply for
// one command; false means an error reply was already sent and the
// script hook must not run.
func (c *conn) applyCommandLocked(sess *Session, cmd proto.Command) bool {
	switch cmd.Cmd {
	case proto.CmdPrompt, proto.CmdSteer, proto.CmdFollowUp:
		var body proto.PromptBody
		if err := json.Unmarshal(cmd.Body, &body); err != nil {
			c.sendError(cmd.ID, proto.ErrBadRequest, err.Error())
			return false
		}
		if !sess.hasStrandLocked(body.Strand) {
			c.sendError(cmd.ID, proto.ErrUnknownStrand, "no strand "+body.Strand)
			return false
		}
		live := sess.liveOpLocked(body.Strand)
		if cmd.Cmd == proto.CmdPrompt && live != "" {
			c.sendError(cmd.ID, proto.ErrConflict, "strand "+body.Strand+" has a live operation")
			return false
		}
		if cmd.Cmd == proto.CmdSteer && live == "" {
			c.sendError(cmd.ID, proto.ErrConflict, "strand "+body.Strand+" has no live operation to steer")
			return false
		}
		entry := UserEntry(sess.mintIDLocked(), body.Text)
		sess.appendEntryLocked(body.Strand, entry, c, cmd.ID)
		return true
	case proto.CmdAbort:
		var body proto.AbortBody
		if err := json.Unmarshal(cmd.Body, &body); err != nil {
			c.sendError(cmd.ID, proto.ErrBadRequest, err.Error())
			return false
		}
		op := sess.liveOpLocked(body.Strand)
		if op == "" {
			c.sendError(cmd.ID, proto.ErrConflict, "no live operation on "+body.Strand)
			return false
		}
		sess.broadcastLocked(proto.EventOpTransition, proto.OpTransitionBody{
			Op: op, Strand: body.Strand, Phase: proto.PhaseCancelRequested,
		}, c, cmd.ID)
		return true
	case proto.CmdApprove:
		var body proto.ApproveBody
		if err := json.Unmarshal(cmd.Body, &body); err != nil {
			c.sendError(cmd.ID, proto.ErrBadRequest, err.Error())
			return false
		}
		return c.decideEscalationLocked(sess, cmd.ID, body.EscalationID, proto.EscalationApproved)
	case proto.CmdDeny:
		var body proto.DenyBody
		if err := json.Unmarshal(cmd.Body, &body); err != nil {
			c.sendError(cmd.ID, proto.ErrBadRequest, err.Error())
			return false
		}
		return c.decideEscalationLocked(sess, cmd.ID, body.EscalationID, proto.EscalationRejected)
	case proto.CmdFork:
		var body proto.ForkBody
		if err := json.Unmarshal(cmd.Body, &body); err != nil {
			c.sendError(cmd.ID, proto.ErrBadRequest, err.Error())
			return false
		}
		if !sess.hasStrandLocked(body.Strand) {
			c.sendError(cmd.ID, proto.ErrUnknownStrand, "no strand "+body.Strand)
			return false
		}
		name := body.Name
		if name == "" {
			name = fmt.Sprintf("fork-%d", len(sess.strands))
		}
		sess.strands = append(sess.strands, proto.Strand{ID: name, Name: name, Leaf: sess.leafLocked(body.Strand)})
		c.strandsReplyLocked(sess, cmd.ID)
		return true
	case proto.CmdCreateStrand:
		var body proto.CreateStrandBody
		if err := json.Unmarshal(cmd.Body, &body); err != nil {
			c.sendError(cmd.ID, proto.ErrBadRequest, err.Error())
			return false
		}
		name := body.Name
		if name == "" {
			name = fmt.Sprintf("strand-%d", len(sess.strands))
		}
		sess.strands = append(sess.strands, proto.Strand{ID: name, Name: name})
		c.strandsReplyLocked(sess, cmd.ID)
		return true
	case proto.CmdNavigate:
		var body proto.NavigateBody
		if err := json.Unmarshal(cmd.Body, &body); err != nil {
			c.sendError(cmd.ID, proto.ErrBadRequest, err.Error())
			return false
		}
		for i := range sess.strands {
			if sess.strands[i].ID == body.Strand {
				sess.strands[i].Leaf = body.ToEntry
			}
		}
		c.strandsReplyLocked(sess, cmd.ID)
		return true
	case proto.CmdCompact:
		var body proto.CompactBody
		if err := json.Unmarshal(cmd.Body, &body); err != nil {
			c.sendError(cmd.ID, proto.ErrBadRequest, err.Error())
			return false
		}
		if !sess.hasStrandLocked(body.Strand) {
			c.sendError(cmd.ID, proto.ErrUnknownStrand, "no strand "+body.Strand)
			return false
		}
		sess.broadcastLocked(proto.EventOpTransition, proto.OpTransitionBody{
			Op: "op-compact", Strand: body.Strand, Phase: proto.PhaseCompacting,
		}, c, cmd.ID)
		return true
	case proto.CmdSetConfig:
		var body proto.SetConfigBody
		if err := json.Unmarshal(cmd.Body, &body); err != nil {
			c.sendError(cmd.ID, proto.ErrBadRequest, err.Error())
			return false
		}
		raw, _ := json.Marshal(body.Config)
		c.sendReply(cmd.ID, proto.EventSnapshot, proto.SnapshotBody{
			Mode: proto.SnapshotConfig, Config: raw,
		})
		return true
	default:
		c.sendError(cmd.ID, proto.ErrUnsupported, "unknown cmd "+cmd.Cmd)
		return false
	}
}

func (c *conn) strandsReplyLocked(sess *Session, replyTo uint64) {
	strands := make([]proto.Strand, len(sess.strands))
	copy(strands, sess.strands)
	c.sendReply(replyTo, proto.EventSnapshot, proto.SnapshotBody{
		Mode: proto.SnapshotStrands, Strands: strands,
	})
}

func (c *conn) decideEscalationLocked(sess *Session, replyTo uint64, id, status string) bool {
	st, ok := sess.escalations[id]
	if !ok {
		c.sendError(replyTo, proto.ErrUnknownEscalation, "no escalation "+id)
		return false
	}
	if st.body.Status != proto.EscalationPending {
		c.sendError(replyTo, proto.ErrNotPending, "escalation "+id+" is "+st.body.Status)
		return false
	}
	st.body.Status = status
	st.body.Denial = nil
	sess.broadcastLocked(proto.EventEscalation, proto.EscalationBody{
		EscalationID: id, Op: st.body.Op, Strand: st.body.Strand, Status: status,
	}, c, replyTo)
	return true
}

func (sess *Session) hasStrandLocked(id string) bool {
	for _, s := range sess.strands {
		if s.ID == id {
			return true
		}
	}
	return false
}

func (sess *Session) leafLocked(id string) string {
	for _, s := range sess.strands {
		if s.ID == id {
			return s.Leaf
		}
	}
	return ""
}

func (sess *Session) liveOpLocked(id string) string {
	for _, s := range sess.strands {
		if s.ID == id && s.LiveOp != nil {
			return s.LiveOp.Op
		}
	}
	return ""
}

// mintIDLocked mints a fake but unique entry id.
func (sess *Session) mintIDLocked() string {
	return fmt.Sprintf("%s-e%06d", sess.id, sess.nextSeq)
}
