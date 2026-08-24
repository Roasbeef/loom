package client

import (
	"context"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/roasbeef/loom/tui/internal/fake"
	"github.com/roasbeef/loom/tui/internal/proto"
)

// harness spins up a fake gateway with one session and a running
// client against it.
type harness struct {
	t      *testing.T
	server *fake.Server
	sess   *fake.Session
	client *Client
	cancel context.CancelFunc
	done   chan error
}

func newHarness(t *testing.T, session string) *harness {
	t.Helper()
	server := fake.NewServer("")
	sess := server.AddSession(session)
	sess.SetStrands(proto.Strand{ID: "main", Name: "main"})
	ts := httptest.NewServer(server.Handler())
	t.Cleanup(ts.Close)

	c := New(Config{
		Addr: "ws" + strings.TrimPrefix(ts.URL, "http") + "/v1/ws", Session: session,
		BackoffBase: 5 * time.Millisecond, BackoffMax: 20 * time.Millisecond,
	})
	ctx, cancel := context.WithCancel(context.Background())
	done := make(chan error, 1)
	go func() { done <- c.Run(ctx) }()
	t.Cleanup(func() {
		cancel()
		select {
		case <-done:
		case <-time.After(5 * time.Second):
			t.Error("client did not stop")
		}
	})
	return &harness{t: t, server: server, sess: sess, client: c, cancel: cancel, done: done}
}

// next pulls one message, failing the test on timeout.
func (h *harness) next() Msg {
	h.t.Helper()
	select {
	case msg, ok := <-h.client.Messages():
		if !ok {
			h.t.Fatal("message channel closed")
		}
		return msg
	case <-time.After(5 * time.Second):
		h.t.Fatal("timed out waiting for a client message")
		return nil
	}
}

// waitSnapshot consumes messages until the first full snapshot.
func (h *harness) waitSnapshot() SnapshotMsg {
	h.t.Helper()
	for {
		if snap, ok := h.next().(SnapshotMsg); ok && snap.Body.Mode == proto.SnapshotFull {
			return snap
		}
	}
}

func TestSubscribeSnapshot(t *testing.T) {
	h := newHarness(t, "s1")
	h.sess.AppendEntry("main", fake.UserEntry("e1", "hello"))

	snap := h.waitSnapshot()
	if snap.Body.Session != "s1" {
		t.Fatalf("wrong session: %+v", snap.Body)
	}
	if len(snap.Body.Strands) != 1 || snap.Body.Strands[0].ID != "main" {
		t.Fatalf("wrong strands: %+v", snap.Body.Strands)
	}
}

func TestPromptReply(t *testing.T) {
	h := newHarness(t, "s1")
	h.waitSnapshot()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	ev, err := h.client.Request(ctx, proto.CmdPrompt, proto.PromptBody{Strand: "main", Text: "hi"})
	if err != nil {
		t.Fatal(err)
	}
	if ev.Event != proto.EventEntry {
		t.Fatalf("prompt answered with %s", ev.Event)
	}
	body, err := ev.Entry()
	if err != nil {
		t.Fatal(err)
	}
	entry, err := proto.ParseEntry(body.Entry)
	if err != nil {
		t.Fatal(err)
	}
	if entry.Message.Role != proto.RoleUser || entry.Message.Content[0].Text != "hi" {
		t.Fatalf("wrong echoed entry: %+v", entry)
	}
}

func TestErrorReply(t *testing.T) {
	h := newHarness(t, "s1")
	h.waitSnapshot()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	ev, err := h.client.Request(ctx, proto.CmdSteer, proto.SteerBody{Strand: "main", Text: "x"})
	if err != nil {
		t.Fatal(err)
	}
	if ev.Event != proto.EventError {
		t.Fatalf("steer on idle strand answered with %s", ev.Event)
	}
	body, err := ev.Error()
	if err != nil {
		t.Fatal(err)
	}
	if body.Code != proto.ErrConflict {
		t.Fatalf("want conflict, got %+v", body)
	}
}

// TestReconnectCatchUp is the load-bearing test: drop the connection
// mid-stream, emit more events while disconnected, and require every
// durable event to arrive exactly once, in seq order.
func TestReconnectCatchUp(t *testing.T) {
	h := newHarness(t, "s1")
	h.waitSnapshot()

	const total = 20
	seen := make(map[uint64]int)
	var order []uint64
	texts := make(map[string]int)

	emit := func(from, to int) {
		for i := from; i <= to; i++ {
			h.sess.AppendEntry("main", fake.UserEntry(
				// Distinct ids and texts so duplicates are visible in
				// content as well as in seq.
				fakeID(i), fakeText(i),
			))
		}
	}

	emit(1, 8)
	// Consume until we have seen 8 entries, then cut the wire.
	for len(order) < 8 {
		if em, ok := h.next().(EntryMsg); ok {
			seen[em.Seq]++
			order = append(order, em.Seq)
			texts[em.Entry.Message.Content[0].Text]++
		}
	}
	h.sess.DropConns()
	// Events emitted while the client is gone must be replayed.
	emit(9, total)

	deadline := time.After(10 * time.Second)
	for len(order) < total {
		select {
		case msg, ok := <-h.client.Messages():
			if !ok {
				t.Fatal("channel closed early")
			}
			if em, ok := msg.(EntryMsg); ok {
				seen[em.Seq]++
				order = append(order, em.Seq)
				texts[em.Entry.Message.Content[0].Text]++
			}
		case <-deadline:
			t.Fatalf("timed out; got %d entries: %v", len(order), order)
		}
	}

	for seq, n := range seen {
		if n != 1 {
			t.Errorf("seq %d delivered %d times", seq, n)
		}
	}
	for text, n := range texts {
		if n != 1 {
			t.Errorf("entry %q delivered %d times", text, n)
		}
	}
	for i := 1; i < len(order); i++ {
		if order[i] <= order[i-1] {
			t.Fatalf("out of order at %d: %v", i, order)
		}
	}
}

// TestReconnectRepeatedDrops hammers the drop path: after every couple
// of events the connection dies; the stream must still be exactly-once
// and ordered.
func TestReconnectRepeatedDrops(t *testing.T) {
	h := newHarness(t, "s1")
	h.waitSnapshot()

	const total = 30
	go func() {
		for i := 1; i <= total; i++ {
			h.sess.AppendEntry("main", fake.UserEntry(fakeID(i), fakeText(i)))
			if i%5 == 0 {
				h.sess.DropConns()
			}
			time.Sleep(2 * time.Millisecond)
		}
	}()

	seen := make(map[uint64]int)
	count := 0
	deadline := time.After(15 * time.Second)
	var last uint64
	for count < total {
		select {
		case msg, ok := <-h.client.Messages():
			if !ok {
				t.Fatal("channel closed early")
			}
			if em, ok := msg.(EntryMsg); ok {
				if em.Seq <= last {
					t.Fatalf("duplicate or reordered seq %d after %d", em.Seq, last)
				}
				last = em.Seq
				seen[em.Seq]++
				count++
			}
		case <-deadline:
			t.Fatalf("timed out with %d/%d entries", count, total)
		}
	}
	for seq, n := range seen {
		if n != 1 {
			t.Errorf("seq %d delivered %d times", seq, n)
		}
	}
}

func TestBadTokenRefused(t *testing.T) {
	server := fake.NewServer("secret")
	server.AddSession("s1")
	ts := httptest.NewServer(server.Handler())
	defer ts.Close()

	c := New(Config{
		Addr: "ws" + strings.TrimPrefix(ts.URL, "http") + "/v1/ws", Session: "s1",
		Token: "wrong", BackoffBase: time.Millisecond, BackoffMax: 2 * time.Millisecond,
	})
	ctx, cancel := context.WithTimeout(context.Background(), 500*time.Millisecond)
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- c.Run(ctx) }()

	sawReconnecting := false
	for msg := range c.Messages() {
		if st, ok := msg.(StateMsg); ok {
			if st.State == StateConnected {
				t.Fatal("connected with a bad token")
			}
			if st.State == StateReconnecting {
				sawReconnecting = true
			}
		}
	}
	<-done
	if !sawReconnecting {
		t.Fatal("never observed a failed dial")
	}
}

func fakeID(i int) string   { return "entry-" + string(rune('a'+i/26)) + string(rune('a'+i%26)) }
func fakeText(i int) string { return "message number " + fakeID(i) }
