package server

import (
	"bytes"
	"fmt"
	"sync"

	"github.com/roasbeef/loom/sandbox/internal/framing"
	"github.com/roasbeef/loom/sandbox/internal/jail"
	"github.com/roasbeef/loom/sandbox/internal/policy"
	"github.com/vmihailenco/msgpack/v5"
)

// creditWriter owns exactly one data, one control and one lifecycle slot.
// Slots include the currently blocked Write. Admission never waits on I/O;
// overflow fences the connection instead of borrowing another slot.
type creditWriter struct {
	conn    *framing.Conn
	mu      sync.Mutex
	changed *sync.Cond
	slots   [3]*creditWrite
	failed  bool
	done    chan struct{}
}

type creditWrite struct {
	packet  []byte
	flushed chan error
}

const (
	creditData = iota
	creditControl
	creditLifecycle
)

func newCreditWriter(conn *framing.Conn) *creditWriter {
	w := &creditWriter{conn: conn, done: make(chan struct{})}
	w.changed = sync.NewCond(&w.mu)
	go w.run()
	return w
}

// Compact ordinals keep the full original ACK envelope within its 128-byte
// bound. Ordinary execution keeps its existing MarshalBody encoding untouched.
func marshalCreditBody(body any) (msgpack.RawMessage, error) {
	var buffer bytes.Buffer
	encoder := msgpack.NewEncoder(&buffer)
	encoder.UseCompactInts(true)
	if err := encoder.Encode(body); err != nil {
		return nil, err
	}
	return buffer.Bytes(), nil
}

func (w *creditWriter) offer(slot int, id uint64, kind string, body any) (<-chan error, bool) {
	raw, err := marshalCreditBody(body)
	if err != nil {
		w.abort()
		return nil, false
	}
	limit := 128
	if slot == creditData {
		limit = 32*1024 + 256
	}
	if slot == creditLifecycle && kind == framing.KindExecExit {
		limit = 32 * 1024
	}
	if len(raw) > limit {
		w.abort()
		return nil, false
	}
	w.mu.Lock()
	if w.failed || w.slots[slot] != nil {
		w.mu.Unlock()
		w.abort()
		return nil, false
	}
	packet, err := framing.EncodeFrame(framing.Frame{V: framing.EnvelopeVersion, ID: id, Kind: kind, Body: raw})
	if err != nil {
		w.mu.Unlock()
		w.abort()
		return nil, false
	}
	if len(packet) > limit {
		w.mu.Unlock()
		w.abort()
		return nil, false
	}
	item := &creditWrite{packet: packet, flushed: make(chan error, 1)}
	w.slots[slot] = item
	w.changed.Signal()
	w.mu.Unlock()
	return item.flushed, true
}

func (w *creditWriter) abort() {
	w.mu.Lock()
	w.failed = true
	w.changed.Broadcast()
	w.mu.Unlock()
	w.conn.Abort()
}

func (w *creditWriter) run() {
	defer close(w.done)
	for {
		w.mu.Lock()
		for !w.failed && w.slots[0] == nil && w.slots[1] == nil && w.slots[2] == nil {
			w.changed.Wait()
		}
		if w.failed {
			for i, item := range w.slots {
				if item != nil {
					item.flushed <- fmt.Errorf("credited channel fenced")
					w.slots[i] = nil
				}
			}
			w.mu.Unlock()
			return
		}
		slot := creditLifecycle
		if w.slots[slot] == nil {
			slot = creditControl
		}
		if w.slots[slot] == nil {
			slot = creditData
		}
		item := w.slots[slot]
		w.mu.Unlock()

		err := w.conn.WriteEncoded(item.packet)
		w.mu.Lock()
		w.slots[slot] = nil
		w.changed.Broadcast()
		item.flushed <- err
		w.mu.Unlock()
		if err != nil {
			w.abort()
		}
	}
}

// protocolRun keeps gates local to the original execution. A single worker
// admits stdin, and a shared output gate lets only one pump offer a chunk.
type protocolRun struct {
	id         uint64
	mode       string
	writer     *creditWriter
	ex         *jail.Exec
	inputPut   func([]byte, bool) error
	mu         sync.Mutex
	changed    *sync.Cond
	pending    *framing.ProtocolInput
	nextInput  uint64
	inputBytes uint64
	sealed     bool
	failed     bool
	inputDone  chan struct{}
	nextOutput uint64
	offered    uint64
	consumed   uint64
}

func newProtocolRun(id uint64, mode string, w *creditWriter) *protocolRun {
	p := &protocolRun{id: id, mode: mode, writer: w, nextInput: 1, nextOutput: 1, inputDone: make(chan struct{})}
	p.changed = sync.NewCond(&p.mu)
	return p
}

// Pumps start inside jail.StartProtocol, before it returns the original Exec.
// Attachment must observe an already-failed gate and cancel that same execution.
func (p *protocolRun) attachOriginal(ex *jail.Exec) {
	p.mu.Lock()
	p.ex = ex
	failed := p.failed
	p.mu.Unlock()
	if failed {
		ex.Cancel()
	}
}

func (p *protocolRun) original() *jail.Exec {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.ex
}

func (p *protocolRun) seal() {
	p.mu.Lock()
	p.sealed = true
	p.changed.Broadcast()
	p.mu.Unlock()
}

func (p *protocolRun) fail() {
	// A blocked data write cannot be joined by releasing output credit alone.
	// Closing this credited transport interrupts it and retains failure instead.
	p.writer.mu.Lock()
	blockedWrite := p.writer.slots[creditData] != nil || p.writer.slots[creditControl] != nil || p.writer.slots[creditLifecycle] != nil
	p.writer.mu.Unlock()
	if blockedWrite {
		p.writer.abort()
	}
	p.mu.Lock()
	p.failed = true
	p.sealed = true
	p.changed.Broadcast()
	p.mu.Unlock()
}

// Final drain expiry closes writer admission even when all slots are empty.
// A pump may already hold output credit without having offered its write;
// that pump must refuse admission rather than hold the cleanup join open.
func (p *protocolRun) drainExpired() {
	p.writer.abort()
	p.fail()
}

func (p *protocolRun) input(f framing.Frame) {
	var in framing.ProtocolInput
	if err := framing.DecodeBody(f.Body, &in); err != nil {
		p.fence()
		return
	}
	p.mu.Lock()
	reason := ""
	switch {
	case f.ID != p.id || in.ExecutionID != p.id || in.Ordinal != p.nextInput || in.FrameID == 0:
		reason = "identity"
	case p.failed || p.sealed:
		reason = "sealed"
	case p.pending != nil:
		reason = "pending"
	case len(in.Data) > 8192:
		reason = "limit"
	case p.mode == framing.ProtocolFinite && (in.Ordinal != 1 || len(in.Data) != 0 || !in.EOF):
		reason = "finite_input"
	case in.Ordinal > 8192 || p.inputBytes+uint64(len(in.Data)) > 64<<20:
		reason = "limit"
	}
	if reason == "limit" {
		p.failed = true
		p.sealed = true
		p.changed.Broadcast()
	}
	if reason == "" {
		p.pending = &in
		p.changed.Signal()
	}
	p.mu.Unlock()
	if reason != "" {
		_, _ = p.writer.offer(creditControl, p.id, framing.KindProtocolInputRefused, framing.ProtocolInputRefused{
			ExecutionID: in.ExecutionID, Ordinal: in.Ordinal, FrameID: in.FrameID, Reason: reason,
		})
		if reason == "limit" {
			if ex := p.original(); ex != nil {
				ex.Cancel()
			}
		}
	}
}

func (p *protocolRun) admit() {
	defer close(p.inputDone)
	for {
		p.mu.Lock()
		for p.pending == nil && !p.sealed {
			p.changed.Wait()
		}
		if p.pending == nil {
			p.mu.Unlock()
			return
		}
		in := p.pending
		p.mu.Unlock()

		err := p.inputPut(in.Data, in.EOF)
		p.mu.Lock()
		p.pending = nil
		if err == nil {
			p.nextInput++
			p.inputBytes += uint64(len(in.Data))
			if in.EOF {
				p.sealed = true
			}
		} else {
			p.sealed = true
			p.failed = true
		}
		p.mu.Unlock()

		var kind string
		var body any
		if err == nil {
			kind = framing.KindProtocolInputAccepted
			body = framing.ProtocolInputAccepted{ExecutionID: p.id, Ordinal: in.Ordinal, FrameID: in.FrameID}
		} else {
			kind = framing.KindProtocolInputRefused
			body = framing.ProtocolInputRefused{ExecutionID: p.id, Ordinal: in.Ordinal, FrameID: in.FrameID, Reason: "queue_rejected"}
		}
		// Drop the pending payload before publishing the original disposition.
		in = nil
		flushed, ok := p.writer.offer(creditControl, p.id, kind, body)
		if !ok {
			p.fail()
			return
		}
		if err := <-flushed; err != nil {
			p.fail()
			return
		}
	}
}

func (p *protocolRun) output(stream string, data []byte, total uint64, truncated bool) {
	p.mu.Lock()
	for p.offered != 0 && !p.failed {
		p.changed.Wait()
	}
	if p.failed {
		p.mu.Unlock()
		return
	}
	ordinal := p.nextOutput
	p.nextOutput++
	p.offered = ordinal
	p.mu.Unlock()

	flushed, ok := p.writer.offer(creditData, p.id, framing.KindProtocolOutput, framing.ProtocolOutput{
		ExecutionID: p.id, Ordinal: ordinal, Stream: stream, Data: data, Bytes: total, Truncated: truncated,
	})
	if !ok {
		p.fail()
		return
	}
	if err := <-flushed; err != nil {
		p.fail()
		return
	}
	if truncated {
		p.fail()
		if ex := p.original(); ex != nil {
			ex.Cancel()
		}
		return
	}
	p.mu.Lock()
	for p.consumed < ordinal && !p.failed {
		p.changed.Wait()
	}
	if !p.failed {
		p.offered = 0
		p.changed.Broadcast()
	}
	p.mu.Unlock()
}

func (p *protocolRun) consume(f framing.Frame) {
	var body framing.ProtocolOutputConsumed
	if err := framing.DecodeBody(f.Body, &body); err != nil {
		p.fence()
		return
	}
	p.mu.Lock()
	invalid := f.ID != p.id || body.ExecutionID != p.id || body.Ordinal == 0 || body.Ordinal > p.offered && body.Ordinal > p.consumed
	if !p.failed && !invalid && p.offered == body.Ordinal {
		p.consumed = body.Ordinal
		p.changed.Broadcast()
	}
	p.mu.Unlock()
	if invalid {
		p.fence()
	}
}

func (p *protocolRun) fence() {
	p.fail()
	p.writer.abort()
	if ex := p.original(); ex != nil {
		ex.Cancel()
	}
}

func (s *Server) handleProtocolStart(f framing.Frame) {
	if s.protocol != nil && s.protocol.mode == framing.ProtocolServer {
		s.protocolError(f.ID, "server execution requires exact helper retirement")
		return
	}
	if !s.protocolNegotiated {
		s.protocolError(f.ID, "protocol-credit-v1 not negotiated")
		return
	}
	if s.running != nil {
		select {
		case <-s.waitDone:
		default:
			s.protocolError(f.ID, "original execution has not joined")
			return
		}
	}
	var body framing.ProtocolStart
	if err := framing.DecodeBody(f.Body, &body); err != nil {
		s.protocolError(f.ID, err.Error())
		return
	}
	if f.ID == 0 || len(body.Argv) == 0 || len(body.Token) == 0 || (body.Mode != framing.ProtocolServer && body.Mode != framing.ProtocolFinite) {
		s.protocolError(f.ID, "invalid protocol_start")
		return
	}
	pol := s.basePol
	if len(body.Policy) > 0 {
		decoded, err := policy.Decode(body.Policy)
		if err != nil {
			s.protocolError(f.ID, err.Error())
			return
		}
		pol = decoded
	}
	maximumWall := uint64(60)
	if body.Mode == framing.ProtocolServer {
		maximumWall = 12 * 60 * 60
	}
	// Server lifetime belongs to the broker's original elapsed deadline. The
	// frame carries no clock authority; finite collectors still need a wall cap.
	zeroWallRefused := pol.Limits.WallSeconds == 0 && body.Mode != framing.ProtocolServer
	if pol.Limits.OutputBytes == 0 || pol.Limits.OutputBytes > 64<<20 || zeroWallRefused || pol.Limits.WallSeconds > maximumWall {
		s.protocolError(f.ID, "credited policy requires bounded original output and wall limits")
		return
	}
	if body.Mode == framing.ProtocolServer && pol.Network.Mode != policy.NetworkOff {
		s.protocolError(f.ID, "server protocol requires network off")
		return
	}
	if s.creditWriter == nil {
		s.creditWriter = newCreditWriter(s.conn)
	}
	p := newProtocolRun(f.ID, body.Mode, s.creditWriter)
	ex, err := jail.StartProtocol(jail.Request{Argv: body.Argv, Env: body.Env, Cwd: body.Cwd, Policy: pol, ID: f.ID}, s.feat, s.selfExe, p.output,
		jail.ProtocolHooks{ChildExited: p.seal, DrainExpired: p.drainExpired})
	if err != nil {
		s.protocolError(f.ID, err.Error())
		return
	}
	p.attachOriginal(ex)
	p.inputPut = ex.WriteStdin
	s.protocol = p
	s.running = ex
	freed, done := make(chan struct{}), make(chan struct{})
	previous := s.waitDone
	s.execFreed, s.waitDone = freed, done
	go p.admit()
	go s.waitProtocol(p, freed, done, previous, ex.Settle)
}

func (s *Server) waitProtocol(p *protocolRun, freed, done, previous chan struct{}, settle func() (jail.Result, func())) {
	res, release := settle()
	p.seal()
	<-p.inputDone
	p.mu.Lock()
	disposition := "complete"
	if p.failed || p.offered != 0 {
		disposition = "failed"
	}
	p.mu.Unlock()
	close(freed)
	terminal := framing.ProtocolExit{ExecExit: execExit(res), Protocol: disposition}
	flushed, ok := p.writer.offer(creditLifecycle, p.id, framing.KindExecExit, terminal)
	if ok {
		if err := <-flushed; err != nil {
			p.fail()
		}
	} else {
		p.fail()
	}
	release()
	if previous != nil {
		<-previous
	}
	close(done)
	// Only actual join, after terminal flush, can produce finite reuse evidence.
	p.mu.Lock()
	reusable := p.mode == framing.ProtocolFinite && !p.failed && disposition == "complete"
	p.mu.Unlock()
	if reusable {
		_, _ = p.writer.offer(creditLifecycle, p.id, framing.KindProtocolReusable, framing.ProtocolReusable{ExecutionID: p.id})
	}
}
func execExit(res jail.Result) framing.ExecExit {
	return framing.ExecExit{Code: res.Code, Signal: res.Signal, StdoutBytes: res.StdoutBytes, StderrBytes: res.StderrBytes,
		StdoutTruncated: res.StdoutTruncated, StderrTruncated: res.StderrTruncated, Enforcement: res.Enforcement,
		Degraded: res.Degraded, WallMs: res.WallMs, TimedOut: res.TimedOut, Cancelled: res.Cancelled}
}

func (s *Server) protocolError(id uint64, msg string) {
	if s.creditWriter == nil {
		s.creditWriter = newCreditWriter(s.conn)
	}
	_, _ = s.creditWriter.offer(creditControl, id, framing.KindError, framing.ErrorBody{Code: framing.ErrCodeProto, Msg: msg})
}
