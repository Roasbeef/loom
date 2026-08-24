package fake

import (
	"context"
	"encoding/json"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"

	"github.com/roasbeef/loom/tui/internal/proto"
)

// wire is a minimal raw websocket harness so the fake's protocol
// behavior is tested without the client package's bookkeeping.
type wire struct {
	t    *testing.T
	conn *websocket.Conn
	ctx  context.Context
	id   uint64
}

func dialWire(t *testing.T, server *Server) *wire {
	t.Helper()
	ts := httptest.NewServer(server.Handler())
	t.Cleanup(ts.Close)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	t.Cleanup(cancel)
	conn, _, err := websocket.Dial(ctx, "ws"+strings.TrimPrefix(ts.URL, "http")+"/v1/ws", nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { conn.CloseNow() })
	conn.SetReadLimit(16 << 20)
	return &wire{t: t, conn: conn, ctx: ctx}
}

func (w *wire) send(cmd string, body any) uint64 {
	w.t.Helper()
	w.id++
	c, err := proto.NewCommand(w.id, cmd, body)
	if err != nil {
		w.t.Fatal(err)
	}
	data, err := json.Marshal(c)
	if err != nil {
		w.t.Fatal(err)
	}
	if err := w.conn.Write(w.ctx, websocket.MessageText, data); err != nil {
		w.t.Fatal(err)
	}
	return w.id
}

func (w *wire) read() proto.Event {
	w.t.Helper()
	_, data, err := w.conn.Read(w.ctx)
	if err != nil {
		w.t.Fatal(err)
	}
	ev, err := proto.DecodeEvent(data)
	if err != nil {
		w.t.Fatal(err)
	}
	return ev
}

// readReply skips broadcasts until the reply to id arrives.
func (w *wire) readReply(id uint64) proto.Event {
	w.t.Helper()
	for range 50 {
		ev := w.read()
		if ev.ReplyTo == id {
			return ev
		}
	}
	w.t.Fatalf("no reply to %d", id)
	return proto.Event{}
}

func newSession(t *testing.T) (*Server, *Session) {
	t.Helper()
	server := NewServer("")
	sess := server.AddSession("s1")
	sess.SetStrands(proto.Strand{ID: "main", Name: "main"})
	return server, sess
}

func TestEscalationLifecycle(t *testing.T) {
	server, sess := newSession(t)
	w := dialWire(t, server)
	id := w.send(proto.CmdSubscribe, proto.SubscribeBody{Session: "s1"})
	w.readReply(id)

	sess.RaiseEscalation(proto.EscalationBody{
		EscalationID: "esc-1", Op: "op-1", Strand: "main",
		Denial: &proto.Denial{Reason: "no", Source: proto.DenialPolicy},
	})
	ev := w.read()
	if ev.Event != proto.EventEscalation || ev.Seq == 0 {
		t.Fatalf("raise not broadcast with seq: %+v", ev)
	}

	id = w.send(proto.CmdApprove, proto.ApproveBody{EscalationID: "esc-1"})
	reply := w.readReply(id)
	if reply.Event != proto.EventEscalation {
		t.Fatalf("approve answered with %s", reply.Event)
	}
	body, err := reply.Escalation()
	if err != nil {
		t.Fatal(err)
	}
	if body.Status != proto.EscalationApproved {
		t.Fatalf("status %s", body.Status)
	}

	// A second decision must refuse: not pending any more.
	id = w.send(proto.CmdDeny, proto.DenyBody{EscalationID: "esc-1"})
	reply = w.readReply(id)
	if reply.Event != proto.EventError {
		t.Fatalf("second decision answered with %s", reply.Event)
	}
	errBody, err := reply.Error()
	if err != nil {
		t.Fatal(err)
	}
	if errBody.Code != proto.ErrNotPending {
		t.Fatalf("want not_pending, got %+v", errBody)
	}
}

func TestCommandsBeforeSubscribeRefused(t *testing.T) {
	server, _ := newSession(t)
	w := dialWire(t, server)
	id := w.send(proto.CmdPrompt, proto.PromptBody{Strand: "main", Text: "hi"})
	reply := w.readReply(id)
	if reply.Event != proto.EventError {
		t.Fatalf("got %s", reply.Event)
	}
}

func TestUnknownCommandAnsweredInBand(t *testing.T) {
	server, _ := newSession(t)
	w := dialWire(t, server)
	id := w.send(proto.CmdSubscribe, proto.SubscribeBody{Session: "s1"})
	w.readReply(id)

	id = w.send("replay_all", map[string]any{})
	reply := w.readReply(id)
	body, err := reply.Error()
	if err != nil {
		t.Fatal(err)
	}
	if body.Code != proto.ErrUnsupported {
		t.Fatalf("want unsupported, got %+v", body)
	}
	// The connection survives an unknown command.
	id = w.send(proto.CmdPrompt, proto.PromptBody{Strand: "main", Text: "still here"})
	if reply := w.readReply(id); reply.Event != proto.EventEntry {
		t.Fatalf("connection unusable after unknown cmd: %+v", reply)
	}
}

func TestResumeReplaysBySeq(t *testing.T) {
	server, sess := newSession(t)
	sess.AppendEntry("main", UserEntry("e1", "one"))
	sess.AppendEntry("main", UserEntry("e2", "two"))
	sess.AppendEntry("main", UserEntry("e3", "three"))

	w := dialWire(t, server)
	id := w.send(proto.CmdSubscribe, proto.SubscribeBody{Session: "s1", FromSeq: 2})
	reply := w.readReply(id)
	snap, err := reply.Snapshot()
	if err != nil {
		t.Fatal(err)
	}
	if snap.Mode != proto.SnapshotResume || snap.NextSeq != 4 {
		t.Fatalf("resume header wrong: %+v", snap)
	}
	for _, wantSeq := range []uint64{2, 3} {
		ev := w.read()
		if ev.Event != proto.EventEntry || ev.Seq != wantSeq {
			t.Fatalf("replay wrong at %d: %+v", wantSeq, ev)
		}
	}
}

func TestResumeBeyondStreamFallsBackToFullSnapshot(t *testing.T) {
	server, sess := newSession(t)
	sess.AppendEntry("main", UserEntry("e1", "one"))

	w := dialWire(t, server)
	id := w.send(proto.CmdSubscribe, proto.SubscribeBody{Session: "s1", FromSeq: 99})
	reply := w.readReply(id)
	snap, err := reply.Snapshot()
	if err != nil {
		t.Fatal(err)
	}
	if snap.Mode != proto.SnapshotFull {
		t.Fatalf("want full-snapshot reset, got %+v", snap)
	}
}

func TestUnknownSessionRefused(t *testing.T) {
	server, _ := newSession(t)
	w := dialWire(t, server)
	id := w.send(proto.CmdSubscribe, proto.SubscribeBody{Session: "nope"})
	reply := w.readReply(id)
	body, err := reply.Error()
	if err != nil {
		t.Fatal(err)
	}
	if body.Code != proto.ErrUnknownSession {
		t.Fatalf("want unknown_session, got %+v", body)
	}
}

func TestModelsAndSwitchByName(t *testing.T) {
	server, sess := newSession(t)
	sess.SetModels(
		proto.ModelInfo{Name: "anthropic-opus", Dialect: "anthropic", ModelID: "claude-opus-5",
			Roles: []string{"main"}, Active: []string{"main"}},
		proto.ModelInfo{Name: "baseten-oss", Dialect: "openai", ModelID: "openai/gpt-oss-120b",
			Roles: []string{"main"}, Active: []string{}},
	)
	w := dialWire(t, server)
	id := w.send(proto.CmdSubscribe, proto.SubscribeBody{Session: "s1"})
	w.readReply(id)

	// The catalogue comes back as a models snapshot.
	id = w.send(proto.CmdModels, proto.ModelsBody{})
	reply := w.readReply(id)
	body, err := reply.Snapshot()
	if err != nil {
		t.Fatal(err)
	}
	if body.Mode != proto.SnapshotModels || len(body.Models) != 2 {
		t.Fatalf("wrong models snapshot: %+v", body)
	}
	if body.Models[1].Name != "baseten-oss" || body.Models[1].Dialect != "openai" {
		t.Fatalf("catalogue rows lost: %+v", body.Models)
	}

	// Switching by a known name acks with the config echoed.
	id = w.send(proto.CmdSetConfig, proto.SetConfigBody{
		Strand: "main", Config: map[string]any{"model_name": "baseten-oss"},
	})
	reply = w.readReply(id)
	body, err = reply.Snapshot()
	if err != nil {
		t.Fatal(err)
	}
	if body.Mode != proto.SnapshotConfig || !strings.Contains(string(body.Config), "baseten-oss") {
		t.Fatalf("wrong config ack: %+v", body)
	}

	// An unknown name refuses in-band and applies nothing.
	id = w.send(proto.CmdSetConfig, proto.SetConfigBody{
		Strand: "main", Config: map[string]any{"model_name": "ghost"},
	})
	reply = w.readReply(id)
	if reply.Event != proto.EventError {
		t.Fatalf("unknown name accepted: %+v", reply)
	}
	errBody, err := reply.Error()
	if err != nil {
		t.Fatal(err)
	}
	if errBody.Code != proto.ErrBadRequest {
		t.Fatalf("wrong code: %+v", errBody)
	}
}
