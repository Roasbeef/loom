// Package client owns the websocket connection to a ClientGateway: it
// dials, subscribes, decodes events into typed messages on a channel,
// reconnects with resume/catch-up semantics, and correlates
// request/reply by command id.
//
// Websocket library: github.com/coder/websocket (the maintained home of
// nhooyr.io/websocket). Chosen over gorilla/websocket because its API
// is context-aware end to end (dial, read, write all take a
// context, which matches this package's cancellation story), it is
// small, actively maintained, and its concurrency rules (one reader,
// writes serialized internally) fit the single-reader/single-writer
// pump below without extra locking.
package client

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math/rand/v2"
	"net/http"
	"sync"
	"sync/atomic"
	"time"

	"github.com/coder/websocket"

	"github.com/roasbeef/loom/tui/internal/proto"
)

// ConnState is the connection lifecycle position, for the status bar.
type ConnState int

const (
	StateConnecting ConnState = iota
	StateConnected
	StateReconnecting
	StateClosed
)

// String renders the state for display.
func (s ConnState) String() string {
	switch s {
	case StateConnecting:
		return "connecting"
	case StateConnected:
		return "connected"
	case StateReconnecting:
		return "reconnecting"
	case StateClosed:
		return "closed"
	default:
		return "unknown"
	}
}

// Msg is one message delivered on Messages(): one of the concrete
// message structs below.
type Msg any

// StateMsg reports a connection state change.
type StateMsg struct {
	State ConnState
	Err   error
}

// SnapshotMsg carries a snapshot event.
type SnapshotMsg struct {
	ReplyTo uint64
	Body    proto.SnapshotBody
}

// EntryMsg carries an appended entry, parsed; Raw keeps the verbatim
// core-codec encoding.
type EntryMsg struct {
	Seq     uint64
	ReplyTo uint64
	Strand  string
	Entry   proto.Entry
	Raw     json.RawMessage
}

// OpTransitionMsg carries an operation phase change.
type OpTransitionMsg struct {
	Seq     uint64
	ReplyTo uint64
	Body    proto.OpTransitionBody
}

// StreamDeltaMsg carries an ephemeral streaming fragment.
type StreamDeltaMsg struct {
	Body proto.StreamDeltaBody
}

// UsageMsg carries a usage-ledger append.
type UsageMsg struct {
	Seq  uint64
	Body proto.UsageBody
}

// EscalationMsg carries an escalation lifecycle event.
type EscalationMsg struct {
	Seq     uint64
	ReplyTo uint64
	Body    proto.EscalationBody
}

// StrandResultMsg carries a strand's terminal result.
type StrandResultMsg struct {
	Seq  uint64
	Body proto.StrandResultBody
}

// ServerErrorMsg carries an in-band error event.
type ServerErrorMsg struct {
	ReplyTo uint64
	Body    proto.ErrorBody
}

// UnknownEventMsg carries an event this client does not know, raw (old
// clients survive new servers).
type UnknownEventMsg struct {
	Name string
	Body json.RawMessage
}

// DecodeErrorMsg reports a malformed frame or body. The connection
// survives; the fault is surfaced instead of crashing.
type DecodeErrorMsg struct {
	Err error
}

// Config configures a Client. Addr is the full websocket URL of the
// gateway endpoint (e.g. ws://127.0.0.1:7777/v1/ws); Token, when
// non-empty, is sent as a bearer token on the upgrade request.
type Config struct {
	Addr    string
	Session string
	Token   string

	// BackoffBase/BackoffMax bound the reconnect backoff; zero values
	// take the defaults (100ms, 5s).
	BackoffBase time.Duration
	BackoffMax  time.Duration
}

// ErrDisconnected fails in-flight requests when their connection drops
// before the reply arrives.
var ErrDisconnected = errors.New("client: connection lost before reply")

// ErrClosed fails sends after the client stopped.
var ErrClosed = errors.New("client: closed")

// Client is the connection actor. Construct with New, drive with Run,
// consume Messages, and issue commands with Send or Request.
type Client struct {
	cfg  Config
	msgs chan Msg
	out  chan proto.Command

	nextID  atomic.Uint64
	lastSeq atomic.Uint64

	mu      sync.Mutex
	pending map[uint64]chan proto.Event
	closed  bool

	// haveSnapshot flips once a full snapshot has been applied; before
	// that, reconnects re-subscribe from zero.
	haveSnapshot atomic.Bool
	// catchUpFrom is non-zero while a gap-triggered catch_up is in
	// flight, suppressing duplicate requests.
	catchUpFrom atomic.Uint64
}

// New builds a client; Run must be called to connect.
func New(cfg Config) *Client {
	if cfg.BackoffBase <= 0 {
		cfg.BackoffBase = 100 * time.Millisecond
	}
	if cfg.BackoffMax <= 0 {
		cfg.BackoffMax = 5 * time.Second
	}
	return &Client{
		cfg: cfg, msgs: make(chan Msg, 256),
		out: make(chan proto.Command, 64), pending: make(map[uint64]chan proto.Event),
	}
}

// Messages is the stream of typed messages. It is closed when Run
// returns.
func (c *Client) Messages() <-chan Msg {
	return c.msgs
}

// LastSeq is the highest durable-event seq observed, for tests and
// diagnostics.
func (c *Client) LastSeq() uint64 {
	return c.lastSeq.Load()
}

// Send queues a command for delivery, returning its id for reply
// correlation. Commands queue across reconnects; the queue bounds
// unacknowledged output (a full queue is an error, not a stall).
func (c *Client) Send(cmd string, body any) (uint64, error) {
	id := c.nextID.Add(1)
	command, err := proto.NewCommand(id, cmd, body)
	if err != nil {
		return 0, err
	}
	c.mu.Lock()
	closed := c.closed
	c.mu.Unlock()
	if closed {
		return 0, ErrClosed
	}
	select {
	case c.out <- command:
		return id, nil
	default:
		return 0, fmt.Errorf("client: outbound queue full sending %s", cmd)
	}
}

// Request sends a command and waits for the event that answers it
// (reply_to == id). An error event answers as a value, not an error;
// losing the connection first fails with ErrDisconnected.
func (c *Client) Request(ctx context.Context, cmd string, body any) (proto.Event, error) {
	ch := make(chan proto.Event, 1)
	id := c.nextID.Add(1)
	command, err := proto.NewCommand(id, cmd, body)
	if err != nil {
		return proto.Event{}, err
	}
	c.mu.Lock()
	if c.closed {
		c.mu.Unlock()
		return proto.Event{}, ErrClosed
	}
	c.pending[id] = ch
	c.mu.Unlock()
	defer func() {
		c.mu.Lock()
		delete(c.pending, id)
		c.mu.Unlock()
	}()
	select {
	case c.out <- command:
	default:
		return proto.Event{}, fmt.Errorf("client: outbound queue full sending %s", cmd)
	}
	select {
	case ev, ok := <-ch:
		if !ok {
			return proto.Event{}, ErrDisconnected
		}
		return ev, nil
	case <-ctx.Done():
		return proto.Event{}, ctx.Err()
	}
}

// Run connects and serves until ctx is cancelled, reconnecting with
// exponential backoff and resuming the event stream by seq. It closes
// Messages on return.
func (c *Client) Run(ctx context.Context) error {
	defer func() {
		c.mu.Lock()
		c.closed = true
		c.failPendingLocked()
		c.mu.Unlock()
		close(c.msgs)
	}()

	attempt := 0
	for {
		if ctx.Err() != nil {
			c.emit(ctx, StateMsg{State: StateClosed})
			return ctx.Err()
		}
		if attempt == 0 {
			c.emit(ctx, StateMsg{State: StateConnecting})
		}
		err := c.serveOnce(ctx)
		if ctx.Err() != nil {
			c.emit(ctx, StateMsg{State: StateClosed})
			return ctx.Err()
		}
		attempt++
		c.emit(ctx, StateMsg{State: StateReconnecting, Err: err})
		select {
		case <-time.After(c.backoff(attempt)):
		case <-ctx.Done():
			c.emit(ctx, StateMsg{State: StateClosed})
			return ctx.Err()
		}
	}
}

// backoff is exponential from BackoffBase, capped at BackoffMax, with
// ±25% jitter so a fleet of clients does not thunder.
func (c *Client) backoff(attempt int) time.Duration {
	d := c.cfg.BackoffBase
	for i := 1; i < attempt && d < c.cfg.BackoffMax; i++ {
		d *= 2
	}
	d = min(d, c.cfg.BackoffMax)
	jitter := time.Duration(rand.Int64N(int64(d)/2+1)) - d/4
	return d + jitter
}

// serveOnce runs one connection to completion: dial, subscribe, pump
// reads and writes. The returned error says why the connection ended.
func (c *Client) serveOnce(ctx context.Context) error {
	dialCtx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()
	opts := &websocket.DialOptions{}
	if c.cfg.Token != "" {
		opts.HTTPHeader = http.Header{"Authorization": {"Bearer " + c.cfg.Token}}
	}
	conn, _, err := websocket.Dial(dialCtx, c.cfg.Addr, opts)
	if err != nil {
		return fmt.Errorf("dial %s: %w", c.cfg.Addr, err)
	}
	defer conn.Close(websocket.StatusNormalClosure, "bye")
	// Large snapshots must not trip the default 32KiB read limit.
	conn.SetReadLimit(16 << 20)

	connCtx, stop := context.WithCancel(ctx)
	defer stop()

	// Subscribe first, before the writer pump can interleave queued
	// commands. A client that has state resumes from lastSeq+1;
	// otherwise it asks for a full snapshot.
	var from uint64
	if c.haveSnapshot.Load() {
		from = c.lastSeq.Load() + 1
	}
	sub, err := proto.NewCommand(c.nextID.Add(1), proto.CmdSubscribe,
		proto.SubscribeBody{Session: c.cfg.Session, FromSeq: from})
	if err != nil {
		return err
	}
	if err := writeCommand(connCtx, conn, sub); err != nil {
		return fmt.Errorf("subscribe: %w", err)
	}
	c.emit(connCtx, StateMsg{State: StateConnected})

	writeErr := make(chan error, 1)
	go func() {
		for {
			select {
			case cmd := <-c.out:
				if err := writeCommand(connCtx, conn, cmd); err != nil {
					writeErr <- err
					return
				}
			case <-connCtx.Done():
				writeErr <- connCtx.Err()
				return
			}
		}
	}()

	readErr := c.readLoop(connCtx, conn)
	stop()
	<-writeErr
	c.mu.Lock()
	c.failPendingLocked()
	c.mu.Unlock()
	c.catchUpFrom.Store(0)
	return readErr
}

func writeCommand(ctx context.Context, conn *websocket.Conn, cmd proto.Command) error {
	data, err := json.Marshal(cmd)
	if err != nil {
		return fmt.Errorf("marshal %s: %w", cmd.Cmd, err)
	}
	return conn.Write(ctx, websocket.MessageText, data)
}

// failPendingLocked closes every pending reply channel; Request maps a
// closed channel to ErrDisconnected.
func (c *Client) failPendingLocked() {
	for id, ch := range c.pending {
		close(ch)
		delete(c.pending, id)
	}
}

// readLoop is the connection's single reader: it decodes each frame,
// resolves any Request awaiting that reply, then applies seq bookkeeping
// and delivers the typed message. It returns (ending the connection)
// only on a read error; a malformed frame is reported and the loop
// continues, matching decode errors elsewhere in this package.
func (c *Client) readLoop(ctx context.Context, conn *websocket.Conn) error {
	for {
		_, data, err := conn.Read(ctx)
		if err != nil {
			return fmt.Errorf("read: %w", err)
		}
		ev, err := proto.DecodeEvent(data)
		if err != nil {
			// A malformed frame is data, not a crash; report and keep
			// the connection.
			c.emit(ctx, DecodeErrorMsg{Err: err})
			continue
		}
		c.resolvePending(ev)
		c.handleEvent(ctx, ev)
	}
}

// resolvePending completes a Request waiting on this event's reply_to.
func (c *Client) resolvePending(ev proto.Event) {
	if ev.ReplyTo == 0 {
		return
	}
	c.mu.Lock()
	ch, ok := c.pending[ev.ReplyTo]
	if ok {
		delete(c.pending, ev.ReplyTo)
	}
	c.mu.Unlock()
	if ok {
		ch <- ev
	}
}

// handleEvent applies seq bookkeeping and delivers the typed message.
//
// Seq discipline: durable events must be observed exactly once, in
// order. Duplicates (catch-up overlap) are dropped by seq; a gap means
// the server-side bus dropped a hint, so the client asks for a replay
// with catch_up and drops the out-of-order event — the replay
// re-delivers it in order.
func (c *Client) handleEvent(ctx context.Context, ev proto.Event) {
	if ev.Seq != 0 {
		last := c.lastSeq.Load()
		switch {
		case ev.Seq <= last:
			return // duplicate from catch-up overlap
		case ev.Seq > last+1 && c.haveSnapshot.Load():
			c.requestCatchUp(last + 1)
			return
		default:
			c.lastSeq.Store(ev.Seq)
			if from := c.catchUpFrom.Load(); from != 0 && ev.Seq >= from {
				c.catchUpFrom.Store(0)
			}
		}
	}

	switch ev.Event {
	case proto.EventSnapshot:
		body, err := ev.Snapshot()
		if err != nil {
			c.emit(ctx, DecodeErrorMsg{Err: err})
			return
		}
		switch body.Mode {
		case proto.SnapshotFull:
			// Full snapshot resets the stream position: everything
			// below next_seq is reflected in the snapshot itself.
			if body.NextSeq > 0 {
				c.lastSeq.Store(body.NextSeq - 1)
			}
			c.haveSnapshot.Store(true)
		case proto.SnapshotResume:
			// Replay follows with original seqs; nothing to reset.
		}
		c.emit(ctx, SnapshotMsg{ReplyTo: ev.ReplyTo, Body: body})
	case proto.EventEntry:
		body, err := ev.Entry()
		if err != nil {
			c.emit(ctx, DecodeErrorMsg{Err: err})
			return
		}
		entry, err := proto.ParseEntry(body.Entry)
		if err != nil {
			c.emit(ctx, DecodeErrorMsg{Err: err})
			return
		}
		c.emit(ctx, EntryMsg{
			Seq: ev.Seq, ReplyTo: ev.ReplyTo, Strand: body.Strand,
			Entry: entry, Raw: body.Entry,
		})
	case proto.EventOpTransition:
		body, err := ev.OpTransition()
		if err != nil {
			c.emit(ctx, DecodeErrorMsg{Err: err})
			return
		}
		c.emit(ctx, OpTransitionMsg{Seq: ev.Seq, ReplyTo: ev.ReplyTo, Body: body})
	case proto.EventStreamDelta:
		body, err := ev.StreamDelta()
		if err != nil {
			c.emit(ctx, DecodeErrorMsg{Err: err})
			return
		}
		c.emit(ctx, StreamDeltaMsg{Body: body})
	case proto.EventUsage:
		body, err := ev.Usage()
		if err != nil {
			c.emit(ctx, DecodeErrorMsg{Err: err})
			return
		}
		c.emit(ctx, UsageMsg{Seq: ev.Seq, Body: body})
	case proto.EventEscalation:
		body, err := ev.Escalation()
		if err != nil {
			c.emit(ctx, DecodeErrorMsg{Err: err})
			return
		}
		c.emit(ctx, EscalationMsg{Seq: ev.Seq, ReplyTo: ev.ReplyTo, Body: body})
	case proto.EventStrandResult:
		body, err := ev.StrandResult()
		if err != nil {
			c.emit(ctx, DecodeErrorMsg{Err: err})
			return
		}
		c.emit(ctx, StrandResultMsg{Seq: ev.Seq, Body: body})
	case proto.EventError:
		body, err := ev.Error()
		if err != nil {
			c.emit(ctx, DecodeErrorMsg{Err: err})
			return
		}
		c.emit(ctx, ServerErrorMsg{ReplyTo: ev.ReplyTo, Body: body})
	default:
		c.emit(ctx, UnknownEventMsg{Name: ev.Event, Body: ev.Body})
	}
}

// requestCatchUp asks for a replay from seq, once per gap.
func (c *Client) requestCatchUp(from uint64) {
	if !c.catchUpFrom.CompareAndSwap(0, from) {
		return
	}
	cmd, err := proto.NewCommand(c.nextID.Add(1), proto.CmdCatchUp, proto.CatchUpBody{FromSeq: from})
	if err != nil {
		return
	}
	select {
	case c.out <- cmd:
	default:
		// Queue full: the reconnect/resubscribe path will converge.
		c.catchUpFrom.Store(0)
	}
}

// emit delivers a message, dropping it only if the consumer is gone.
func (c *Client) emit(ctx context.Context, msg Msg) {
	select {
	case c.msgs <- msg:
	case <-ctx.Done():
	}
}
