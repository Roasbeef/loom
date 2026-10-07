package server

import (
	"bytes"
	"io"
	"math"
	"sync"
	"testing"
	"time"

	"github.com/roasbeef/loom/sandbox/internal/framing"
	"github.com/roasbeef/loom/sandbox/internal/jail"
)

// blockedWrite exposes an I/O hold without spawning a native helper.
type blockedWrite struct {
	entered   chan struct{}
	closed    chan struct{}
	once      sync.Once
	closeOnce sync.Once
}

func (b *blockedWrite) Write(_ []byte) (int, error) {
	b.once.Do(func() { close(b.entered) })
	<-b.closed
	return 0, io.ErrClosedPipe
}
func (b *blockedWrite) Close() error {
	b.closeOnce.Do(func() { close(b.closed) })
	return nil
}

func TestCreditWriterFencesOccupiedControlWithoutWaiting(t *testing.T) {
	sink := &blockedWrite{entered: make(chan struct{}), closed: make(chan struct{})}
	w := newCreditWriter(framing.NewConn(bytes.NewReader(nil), sink))
	_, ok := w.offer(creditControl, 1, framing.KindHeartbeat, map[string]any{})
	if !ok {
		t.Fatal("first bounded control must fit")
	}
	<-sink.entered
	completed := make(chan bool, 1)
	go func() { _, ok := w.offer(creditControl, 2, framing.KindHeartbeat, map[string]any{}); completed <- ok }()
	select {
	case ok := <-completed:
		if ok {
			t.Fatal("occupied control must fence, not queue")
		}
	case <-time.After(time.Second):
		t.Fatal("frame reader blocked on occupied control")
	}
	select {
	case <-w.done:
	case <-time.After(time.Second):
		t.Fatal("blocked writer did not join after fence")
	}
}

func TestOutputCreditSharedAcrossStreamsAndExactCumulativeBytes(t *testing.T) {
	reader, writer := io.Pipe()
	w := newCreditWriter(framing.NewConn(bytes.NewReader(nil), writer))
	p := newProtocolRun(40, framing.ProtocolServer, w)
	firstDone, secondDone := make(chan struct{}), make(chan struct{})
	go func() { p.output("stdout", []byte("abc"), 3, false); close(firstDone) }()
	f, err := framing.ReadFrame(reader)
	if err != nil {
		t.Fatal(err)
	}
	var first framing.ProtocolOutput
	if err := framing.DecodeBody(f.Body, &first); err != nil {
		t.Fatal(err)
	}
	if first.ExecutionID != 40 || first.Ordinal != 1 || first.Bytes != 3 || string(first.Data) != "abc" {
		t.Fatalf("lost original/cumulative output: %+v", first)
	}
	go func() { p.output("stderr", []byte("xy"), 2, false); close(secondDone) }()
	select {
	case <-secondDone:
		t.Fatal("other stream bypassed shared credit")
	default:
	}
	raw, _ := framing.MarshalBody(framing.ProtocolOutputConsumed{ExecutionID: 40, Ordinal: 1})
	p.consume(framing.Frame{ID: 40, Body: raw})
	second, err := framing.ReadFrame(reader)
	if err != nil {
		t.Fatal(err)
	}
	var out framing.ProtocolOutput
	if err := framing.DecodeBody(second.Body, &out); err != nil {
		t.Fatal(err)
	}
	if out.Ordinal != 2 || out.Stream != "stderr" || out.Bytes != 2 {
		t.Fatalf("stream counts were combined: %+v", out)
	}
	raw, _ = framing.MarshalBody(framing.ProtocolOutputConsumed{ExecutionID: 40, Ordinal: 2})
	p.consume(framing.Frame{ID: 40, Body: raw})
	<-firstDone
	<-secondDone
	w.abort()
	<-w.done
	reader.Close()
}

func TestWrongAndLateConsumptionCannotReopenFailedGate(t *testing.T) {
	w := newCreditWriter(framing.NewConn(bytes.NewReader(nil), io.Discard))
	p := newProtocolRun(7, framing.ProtocolServer, w)
	p.offered = 1
	raw, _ := framing.MarshalBody(framing.ProtocolOutputConsumed{ExecutionID: 8, Ordinal: 1})
	p.consume(framing.Frame{ID: 8, Body: raw})
	p.mu.Lock()
	failed := p.failed
	p.mu.Unlock()
	if !failed {
		t.Fatal("foreign witness must fail the protocol")
	}
	raw, _ = framing.MarshalBody(framing.ProtocolOutputConsumed{ExecutionID: 7, Ordinal: 1})
	p.consume(framing.Frame{ID: 7, Body: raw})
	p.mu.Lock()
	offered := p.offered
	consumed := p.consumed
	p.mu.Unlock()
	if offered != 1 || consumed != 0 {
		t.Fatal("late exact witness reopened failed gate")
	}
	w.abort()
	<-w.done
}

func TestCancellationJoinsOutputBlockedInsideChannelWrite(t *testing.T) {
	sink := &blockedWrite{entered: make(chan struct{}), closed: make(chan struct{})}
	w := newCreditWriter(framing.NewConn(bytes.NewReader(nil), sink))
	p := newProtocolRun(6, framing.ProtocolServer, w)
	done := make(chan struct{})
	go func() { p.output("stdout", []byte("held"), 4, false); close(done) }()
	<-sink.entered
	p.fail()
	select {
	case <-done:
	case <-time.After(time.Second):
		t.Fatal("cancel did not release output sink")
	}
	<-w.done
}

func TestFinalDrainFencesOutputBeforeWriterAdmission(t *testing.T) {
	sink := &blockedWrite{entered: make(chan struct{}), closed: make(chan struct{})}
	w := newCreditWriter(framing.NewConn(bytes.NewReader(nil), sink))
	t.Cleanup(func() { w.abort(); <-w.done })
	p := newProtocolRun(6, framing.ProtocolServer, w)
	gateAcquired, admit := make(chan struct{}), make(chan struct{})
	finished := make(chan bool, 1)
	go func() {
		// Hold the same boundary as a pump which owns credit but has not yet
		// admitted its encoded write to the connection's bounded data slot.
		p.mu.Lock()
		ordinal := p.nextOutput
		p.nextOutput++
		p.offered = ordinal
		p.mu.Unlock()
		close(gateAcquired)
		<-admit
		_, ok := w.offer(creditData, p.id, framing.KindProtocolOutput, framing.ProtocolOutput{
			ExecutionID: p.id, Ordinal: ordinal, Stream: "stdout", Data: []byte("held"), Bytes: 4,
		})
		finished <- ok
	}()
	<-gateAcquired
	p.drainExpired()
	close(admit)
	select {
	case ok := <-finished:
		if ok {
			t.Fatal("final drain admitted a write after its empty-slot fence")
		}
	case <-time.After(time.Second):
		t.Fatal("held producer did not join after final drain")
	}
	select {
	case <-w.done:
	case <-time.After(time.Second):
		t.Fatal("empty-slot final drain did not join the writer")
	}
	select {
	case <-sink.entered:
		t.Fatal("held producer entered connection Write after final drain")
	default:
	}
	p.mu.Lock()
	failed, sealed, offered := p.failed, p.sealed, p.offered
	p.mu.Unlock()
	if !failed || !sealed || offered != 1 {
		t.Fatal("final drain lost the original failed credit")
	}
}

func TestCreditControlBodiesFitTheirReservedSlots(t *testing.T) {
	for _, sample := range []struct {
		kind string
		body any
	}{
		{framing.KindProtocolInputAccepted, framing.ProtocolInputAccepted{ExecutionID: math.MaxUint64, Ordinal: 8192, FrameID: math.MaxUint64}},
		{framing.KindProtocolInputRefused, framing.ProtocolInputRefused{ExecutionID: math.MaxUint64, Ordinal: 8192, FrameID: math.MaxUint64, Reason: "queue_rejected"}},
		{framing.KindProtocolReusable, framing.ProtocolReusable{ExecutionID: math.MaxUint64}},
	} {
		raw, err := marshalCreditBody(sample.body)
		if err != nil {
			t.Fatal(err)
		}
		packet, err := framing.EncodeFrame(framing.Frame{V: framing.EnvelopeVersion, ID: math.MaxUint64, Kind: sample.kind, Body: raw})
		if err != nil {
			t.Fatal(err)
		}
		if len(packet) > 128 {
			t.Fatalf("full %s frame exceeds reserved bound: %d", sample.kind, len(packet))
		}
		t.Logf("%s full maximum-identity packet: %d bytes", sample.kind, len(packet))
		if len(packet) == 0 {
			t.Fatal("missing encoded original control")
		}
	}
}

// The terminal is readable while release is deliberately held, but the exact
// reusable witness cannot appear before the original cleanup join completes.
func TestFiniteReusableFollowsActualWaitDone(t *testing.T) {
	reader, writer := io.Pipe()
	w := newCreditWriter(framing.NewConn(bytes.NewReader(nil), writer))
	p := newProtocolRun(19, framing.ProtocolFinite, w)
	close(p.inputDone)
	releaseEntered, release := make(chan struct{}), make(chan struct{})
	freed, done := make(chan struct{}), make(chan struct{})
	s := &Server{creditWriter: w}
	go s.waitProtocol(p, freed, done, nil, func() (jail.Result, func()) {
		return jail.Result{Enforcement: []string{"pgroup"}}, func() { close(releaseEntered); <-release }
	})
	terminal, err := framing.ReadFrame(reader)
	if err != nil {
		t.Fatal(err)
	}
	if terminal.ID != 19 || terminal.Kind != framing.KindExecExit {
		t.Fatalf("wrong original terminal: %+v", terminal)
	}
	<-releaseEntered
	select {
	case <-done:
		t.Fatal("cleanup hold was mistaken for actual waitDone")
	default:
	}
	// No reader exists for the next frame while release is held. A premature
	// reusable admission must still occupy the reserved lifecycle slot.
	w.mu.Lock()
	premature := w.slots[creditLifecycle] != nil
	w.mu.Unlock()
	if premature {
		t.Fatal("terminal flush admitted reusable before cleanup")
	}
	reusable := make(chan framing.Frame, 1)
	go func() { frame, _ := framing.ReadFrame(reader); reusable <- frame }()
	close(release)
	<-done
	select {
	case frame := <-reusable:
		var body framing.ProtocolReusable
		if err := framing.DecodeBody(frame.Body, &body); err != nil {
			t.Fatal(err)
		}
		if frame.ID != 19 || frame.Kind != framing.KindProtocolReusable || body.ExecutionID != 19 {
			t.Fatalf("reuse lost original identity: %+v %+v", frame, body)
		}
	case <-time.After(time.Second):
		t.Fatal("actual join did not publish reuse")
	}
	w.abort()
	<-w.done
	reader.Close()
}

func TestPendingInputAdmissionDoesNotBlockCancellationOrSecondRefusal(t *testing.T) {
	reader, writer := io.Pipe()
	w := newCreditWriter(framing.NewConn(bytes.NewReader(nil), writer))
	p := newProtocolRun(9, framing.ProtocolServer, w)
	entered, release := make(chan struct{}), make(chan struct{})
	p.inputPut = func(data []byte, eof bool) error { close(entered); <-release; return io.ErrClosedPipe }
	go p.admit()
	raw, _ := framing.MarshalBody(framing.ProtocolInput{ExecutionID: 9, Ordinal: 1, FrameID: 70, Data: []byte("held")})
	p.input(framing.Frame{ID: 9, Body: raw})
	<-entered
	raw, _ = framing.MarshalBody(framing.ProtocolInput{ExecutionID: 9, Ordinal: 1, FrameID: 71, Data: []byte("second")})
	returned := make(chan struct{})
	go func() { p.input(framing.Frame{ID: 9, Body: raw}); close(returned) }()
	select {
	case <-returned:
	case <-time.After(time.Second):
		t.Fatal("second frame waited behind put")
	}
	refusal, err := framing.ReadFrame(reader)
	if err != nil {
		t.Fatal(err)
	}
	var body framing.ProtocolInputRefused
	if err := framing.DecodeBody(refusal.Body, &body); err != nil {
		t.Fatal(err)
	}
	if body.FrameID != 71 || body.Reason != "pending" {
		t.Fatalf("second admission was not refused exactly: %+v", body)
	}
	w.mu.Lock()
	for w.slots[creditControl] != nil {
		w.changed.Wait()
	}
	w.mu.Unlock()

	// Seal is a gate transition, independent of the blocked queue admission.
	p.seal()
	close(release)
	refusal, err = framing.ReadFrame(reader)
	if err != nil {
		t.Fatal(err)
	}
	if err := framing.DecodeBody(refusal.Body, &body); err != nil {
		t.Fatal(err)
	}
	if body.FrameID != 70 || body.Reason != "queue_rejected" {
		t.Fatalf("lost original pending disposition: %+v", body)
	}
	select {
	case <-p.inputDone:
	case <-time.After(time.Second):
		t.Fatal("admission worker failed to join")
	}
	w.abort()
	<-w.done
	reader.Close()
}

// Exhaustion cannot renew input through another ordinal or an EOF-only frame.
func TestProtocolInputLifetimeExhaustionSealsAndJoinsAdmission(t *testing.T) {
	reader, writer := io.Pipe()
	w := newCreditWriter(framing.NewConn(bytes.NewReader(nil), writer))
	p := newProtocolRun(8, framing.ProtocolServer, w)
	p.nextInput = 8193
	go p.admit()
	raw, _ := framing.MarshalBody(framing.ProtocolInput{ExecutionID: 8, Ordinal: 8193, FrameID: 7, EOF: true})
	p.input(framing.Frame{ID: 8, Body: raw})
	frame, err := framing.ReadFrame(reader)
	if err != nil {
		t.Fatal(err)
	}
	var refusal framing.ProtocolInputRefused
	if err := framing.DecodeBody(frame.Body, &refusal); err != nil {
		t.Fatal(err)
	}
	if refusal.Reason != "limit" || refusal.Ordinal != 8193 || refusal.FrameID != 7 {
		t.Fatalf("exhaustion changed original refusal: %+v", refusal)
	}
	select {
	case <-p.inputDone:
	case <-time.After(time.Second):
		t.Fatal("exhausted input admission did not join")
	}
	p.mu.Lock()
	sealed, failed := p.sealed, p.failed
	p.mu.Unlock()
	if !sealed || !failed {
		t.Fatal("exhausted input renewed its authority")
	}
	w.abort()
	<-w.done
	reader.Close()
}

// A producer-truncated chunk is retained as failure and never returns credit.
func TestProtocolTruncatedProducerOutputFailsWithoutConsumption(t *testing.T) {
	reader, writer := io.Pipe()
	w := newCreditWriter(framing.NewConn(bytes.NewReader(nil), writer))
	p := newProtocolRun(9, framing.ProtocolFinite, w)
	finished := make(chan struct{})
	go func() { p.output("stdout", []byte("prefix"), 6, true); close(finished) }()
	frame, err := framing.ReadFrame(reader)
	if err != nil {
		t.Fatal(err)
	}
	var output framing.ProtocolOutput
	if err := framing.DecodeBody(frame.Body, &output); err != nil {
		t.Fatal(err)
	}
	if !output.Truncated || output.Bytes != 6 {
		t.Fatal("producer prefix lost its truncation")
	}
	select {
	case <-finished:
	case <-time.After(time.Second):
		t.Fatal("truncated producer waited for consumption")
	}
	p.mu.Lock()
	failed, offered := p.failed, p.offered
	p.mu.Unlock()
	if !failed || offered != 1 {
		t.Fatal("producer truncation was treated as complete consumed output")
	}
	w.abort()
	<-w.done
	reader.Close()
}
