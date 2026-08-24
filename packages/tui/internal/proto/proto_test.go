package proto

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

// commandBody returns a fresh typed body value for a command name.
func commandBody(cmd string) any {
	switch cmd {
	case CmdSubscribe:
		return &SubscribeBody{}
	case CmdCatchUp:
		return &CatchUpBody{}
	case CmdPrompt:
		return &PromptBody{}
	case CmdSteer:
		return &SteerBody{}
	case CmdFollowUp:
		return &FollowUpBody{}
	case CmdAbort:
		return &AbortBody{}
	case CmdApprove:
		return &ApproveBody{}
	case CmdDeny:
		return &DenyBody{}
	case CmdFork:
		return &ForkBody{}
	case CmdNavigate:
		return &NavigateBody{}
	case CmdCompact:
		return &CompactBody{}
	case CmdCreateStrand:
		return &CreateStrandBody{}
	case CmdModels:
		return &ModelsBody{}
	case CmdSetConfig:
		return &SetConfigBody{}
	default:
		return nil
	}
}

// eventBody returns a fresh typed body value for an event name.
func eventBody(event string) any {
	switch event {
	case EventSnapshot:
		return &SnapshotBody{}
	case EventEntry:
		return &EntryBody{}
	case EventOpTransition:
		return &OpTransitionBody{}
	case EventStreamDelta:
		return &StreamDeltaBody{}
	case EventUsage:
		return &UsageBody{}
	case EventEscalation:
		return &EscalationBody{}
	case EventStrandResult:
		return &StrandResultBody{}
	case EventError:
		return &ErrorBody{}
	default:
		return nil
	}
}

// normalize parses JSON into a comparable value so key order and
// whitespace never matter.
func normalize(t *testing.T, data []byte) any {
	t.Helper()
	var v any
	if err := json.Unmarshal(data, &v); err != nil {
		t.Fatalf("normalize: %v\n%s", err, data)
	}
	return v
}

// TestGoldenRoundtrip decodes every fixture, re-encodes its body
// through the typed structs, and requires semantic equality with the
// original. These fixtures are the gateway's conformance corpus (see
// testdata/README.md).
func TestGoldenRoundtrip(t *testing.T) {
	files, err := filepath.Glob(filepath.Join("testdata", "*.json"))
	if err != nil {
		t.Fatal(err)
	}
	if len(files) < 30 {
		t.Fatalf("expected the full fixture corpus, found %d files", len(files))
	}
	for _, file := range files {
		t.Run(filepath.Base(file), func(t *testing.T) {
			data, err := os.ReadFile(file)
			if err != nil {
				t.Fatal(err)
			}
			switch {
			case strings.HasPrefix(filepath.Base(file), "cmd_"):
				roundtripCommand(t, data)
			case strings.HasPrefix(filepath.Base(file), "event_"):
				roundtripEvent(t, data)
			default:
				t.Fatalf("fixture %s has no cmd_/event_ prefix", file)
			}
		})
	}
}

func roundtripCommand(t *testing.T, data []byte) {
	t.Helper()
	cmd, err := DecodeCommand(data)
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	body := commandBody(cmd.Cmd)
	if body == nil {
		t.Fatalf("fixture uses unknown cmd %q", cmd.Cmd)
	}
	if err := json.Unmarshal(cmd.Body, body); err != nil {
		t.Fatalf("typed decode: %v", err)
	}
	re, err := NewCommand(cmd.ID, cmd.Cmd, body)
	if err != nil {
		t.Fatalf("re-encode: %v", err)
	}
	encoded, err := json.Marshal(re)
	if err != nil {
		t.Fatal(err)
	}
	if got, want := normalize(t, encoded), normalize(t, data); !reflect.DeepEqual(got, want) {
		t.Fatalf("roundtrip drift:\n got %s\nwant %s", encoded, data)
	}
}

func roundtripEvent(t *testing.T, data []byte) {
	t.Helper()
	ev, err := DecodeEvent(data)
	if err != nil {
		t.Fatalf("decode: %v", err)
	}
	body := eventBody(ev.Event)
	if body == nil {
		t.Fatalf("fixture uses unknown event %q", ev.Event)
	}
	if err := json.Unmarshal(ev.Body, body); err != nil {
		t.Fatalf("typed decode: %v", err)
	}
	raw, err := json.Marshal(body)
	if err != nil {
		t.Fatal(err)
	}
	re := Event{V: Version, ReplyTo: ev.ReplyTo, Event: ev.Event, Seq: ev.Seq, Body: raw}
	encoded, err := json.Marshal(re)
	if err != nil {
		t.Fatal(err)
	}
	if got, want := normalize(t, encoded), normalize(t, data); !reflect.DeepEqual(got, want) {
		t.Fatalf("roundtrip drift:\n got %s\nwant %s", encoded, data)
	}
}

func TestEnvelopeStrictness(t *testing.T) {
	tests := []struct {
		name  string
		data  string
		event bool
	}{
		{"wrong version command", `{"v":2,"id":1,"cmd":"prompt","body":{}}`, false},
		{"missing cmd", `{"v":1,"id":1,"body":{}}`, false},
		{"missing id", `{"v":1,"cmd":"prompt","body":{}}`, false},
		{"wrong version event", `{"v":9,"event":"entry","body":{}}`, true},
		{"missing event name", `{"v":1,"seq":3,"body":{}}`, true},
		{"not json", `nope`, true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var err error
			if tt.event {
				_, err = DecodeEvent([]byte(tt.data))
			} else {
				_, err = DecodeCommand([]byte(tt.data))
			}
			if err == nil {
				t.Fatalf("expected decode error for %s", tt.data)
			}
		})
	}
}

// TestUnknownNamesTolerated: an old client must survive a new server's
// event names, and a server must see unknown commands as data.
func TestUnknownNamesTolerated(t *testing.T) {
	ev, err := DecodeEvent([]byte(`{"v":1,"event":"telemetry","seq":9,"body":{"heap":123}}`))
	if err != nil {
		t.Fatalf("unknown event rejected: %v", err)
	}
	if ev.Event != "telemetry" || string(ev.Body) != `{"heap":123}` {
		t.Fatalf("raw payload not preserved: %+v", ev)
	}
	cmd, err := DecodeCommand([]byte(`{"v":1,"id":4,"cmd":"replay","body":{"x":1}}`))
	if err != nil {
		t.Fatalf("unknown cmd rejected: %v", err)
	}
	if cmd.Cmd != "replay" || string(cmd.Body) != `{"x":1}` {
		t.Fatalf("raw payload not preserved: %+v", cmd)
	}
}

func TestParseEntry(t *testing.T) {
	data, err := os.ReadFile(filepath.Join("testdata", "event_entry_assistant.json"))
	if err != nil {
		t.Fatal(err)
	}
	ev, err := DecodeEvent(data)
	if err != nil {
		t.Fatal(err)
	}
	body, err := ev.Entry()
	if err != nil {
		t.Fatal(err)
	}
	entry, err := ParseEntry(body.Entry)
	if err != nil {
		t.Fatal(err)
	}
	if entry.Type != EntryMessage || entry.Message.Role != RoleAssistant {
		t.Fatalf("wrong parse: %+v", entry)
	}
	if len(entry.Message.Content) != 3 {
		t.Fatalf("want 3 blocks, got %d", len(entry.Message.Content))
	}
	if entry.Message.Content[2].ToolCall.Name != "bash" {
		t.Fatalf("tool call lost: %+v", entry.Message.Content[2])
	}
	if entry.Message.Usage.TotalTokens != 1500 {
		t.Fatalf("usage lost: %+v", entry.Message.Usage)
	}
}

func TestParseEntryBareStringContent(t *testing.T) {
	raw := json.RawMessage(`{"id":"e1","seq":1,"timestamp":0,"type":"message",` +
		`"message":{"role":"user","content":"hi there","timestamp":0}}`)
	entry, err := ParseEntry(raw)
	if err != nil {
		t.Fatal(err)
	}
	want := []Block{{Type: BlockText, Text: "hi there"}}
	if !reflect.DeepEqual(entry.Message.Content, want) {
		t.Fatalf("bare-string content: %+v", entry.Message.Content)
	}
}

func TestParseEntryRejectsJunk(t *testing.T) {
	for _, raw := range []string{`null`, `{}`, `{"id":"e1"}`, `{"id":"e1","type":"message"}`, `[1,2]`} {
		if _, err := ParseEntry(json.RawMessage(raw)); err == nil {
			t.Fatalf("junk accepted: %s", raw)
		}
	}
}

func TestExitCode(t *testing.T) {
	m := &Message{Details: json.RawMessage(`{"exitCode":2,"durationMs":12}`)}
	code, ok := m.ExitCode()
	if !ok || code != 2 {
		t.Fatalf("got %d %v", code, ok)
	}
	if _, ok := (&Message{}).ExitCode(); ok {
		t.Fatal("exit code from empty details")
	}
	if _, ok := (&Message{Details: json.RawMessage(`{"other":1}`)}).ExitCode(); ok {
		t.Fatal("exit code from unrelated details")
	}
}

func TestGrantDisplay(t *testing.T) {
	tests := []struct {
		grant Grant
		want  string
	}{
		{Grant{Type: GrantNetwork, Network: &Network{Mode: NetworkProxy, Allow: []string{"registry.npmjs.org"}}}, "network to registry.npmjs.org"},
		{Grant{Type: GrantNetwork, Network: &Network{Mode: NetworkFull}}, "unrestricted network"},
		{Grant{Type: GrantWritableRoot, Path: "/work/out"}, "write access to /work/out"},
		{Grant{Type: GrantReadableRoot, Path: "/etc/ssl"}, "read access to /etc/ssl"},
		{Grant{Type: GrantEnv, Name: "NPM_TOKEN"}, "environment variable NPM_TOKEN"},
		{Grant{Type: GrantLimit, Field: LimitPids, Value: 512}, "limit pids = 512"},
		{Grant{Type: GrantScratch, Scratch: &Scratch{Mode: ScratchTmpfs}}, "tmpfs scratch"},
	}
	for _, tt := range tests {
		if got := tt.grant.Display(); got != tt.want {
			t.Errorf("Display(%+v) = %q, want %q", tt.grant, got, tt.want)
		}
	}
}
