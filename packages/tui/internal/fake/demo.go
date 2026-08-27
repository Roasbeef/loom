package fake

import (
	"fmt"
	"strings"
	"sync"
	"time"

	"github.com/roasbeef/loom/tui/internal/proto"
)

// DemoSession populates a server with the canned multi-strand demo
// session behind `loom-tui --demo`: a "main" strand with history and an
// interactive scripted flow, plus a static "research" strand.
//
// Each prompt on "main" plays one full operation: op transitions,
// thinking and text stream deltas, a settled assistant entry with a
// tool call, then a sandbox escalation ("wants: network to
// registry.npmjs.org"). Approving it settles the tool with exit 0 and a
// closing message; denying settles it as a policy-refused failure the
// operation then reports. stepDelay stretches the script for human
// eyes; tests pass something tiny.
func DemoSession(server *Server, stepDelay time.Duration) *Session {
	sess := server.AddSession("demo")
	sess.SetStrands(
		proto.Strand{ID: "main", Name: "main"},
		proto.Strand{ID: "research", Name: "research"},
	)
	// A two-entry catalogue so :models has something to pick from: the
	// routed default plus an OpenAI-dialect alternative (the shape a
	// Baseten endpoint registers as).
	sess.SetModels(
		proto.ModelInfo{Name: "anthropic-opus", Dialect: "anthropic", ModelID: "claude-opus-5",
			Roles: []string{"main", "summarize"}, Active: []string{"main", "summarize"}},
		proto.ModelInfo{Name: "baseten-oss", Dialect: "openai", ModelID: "openai/gpt-oss-120b",
			Roles: []string{"main"}, Active: []string{}},
	)

	sess.AppendEntry("main", UserEntry("demo-hist-1",
		"survey the fetcher package and tell me what is missing"))
	sess.AppendEntry("main", AssistantEntry("demo-hist-2", "stop", SmallUsage(900, 220),
		TextBlock("The fetcher has **no retry policy** and no backoff.\n\n"+
			"- `fetch.go` does one attempt and returns the raw error\n"+
			"- timeouts are hard-coded to 30s\n\n"+
			"I suggest a bounded retry with exponential backoff."),
	))
	sess.AddUsage("main", "op-hist", SmallUsage(900, 220))

	sess.AppendEntry("research", UserEntry("demo-res-1",
		"what does the standard library offer for backoff?"))
	sess.AppendEntry("research", AssistantEntry("demo-res-2", "stop", SmallUsage(500, 180),
		TextBlock("Nothing directly; `time` plus jittered sleeps is idiomatic. "+
			"Third-party options exist but a ten-line loop is usually enough."),
	))
	sess.AddUsage("research", "op-res", SmallUsage(500, 180))

	script := &demoScript{sess: sess, delay: stepDelay}
	sess.SetOnCommand(script.onCommand)
	return sess
}

// demoScript drives the canned operation. One operation runs at a
// time; the pending escalation blocks it until approve/deny.
type demoScript struct {
	sess  *Session
	delay time.Duration

	mu      sync.Mutex
	opN     int
	liveOp  string
	pending string // escalation id awaiting a decision
	callID  string
}

func (d *demoScript) onCommand(sess *Session, cmd proto.Command) {
	switch cmd.Cmd {
	case proto.CmdPrompt:
		d.mu.Lock()
		d.opN++
		op := fmt.Sprintf("op-demo-%d", d.opN)
		d.liveOp = op
		d.mu.Unlock()
		go d.playRun(op)
	case proto.CmdApprove:
		if d.takePending() {
			go d.playApproved()
		}
	case proto.CmdDeny:
		if d.takePending() {
			go d.playDenied()
		}
	}
}

func (d *demoScript) takePending() bool {
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.pending == "" {
		return false
	}
	d.pending = ""
	return true
}

func (d *demoScript) pause() { time.Sleep(d.delay) }

// playRun streams the canned response up to the escalation.
func (d *demoScript) playRun(op string) {
	sess := d.sess
	sess.SetPhase("main", op, proto.PhaseStarting)
	sess.Broadcast(proto.EventOpTransition, proto.OpTransitionBody{
		Op: op, Strand: "main", Phase: proto.PhaseStarting,
	})
	d.pause()

	sess.SetPhase("main", op, proto.PhaseAssistant)
	sess.Broadcast(proto.EventOpTransition, proto.OpTransitionBody{
		Op: op, Strand: "main", Phase: proto.PhaseAssistant,
	})

	thinking := "The retry needs its own package so both the fetcher and the mirror can share it."
	for _, chunk := range chunks(thinking, 24) {
		sess.Ephemeral(proto.StreamDeltaBody{
			Strand: "main", Op: op, Kind: proto.DeltaThinking, Text: chunk,
		})
		d.pause()
	}
	text := "Adding a bounded retry with jittered exponential backoff, then installing the dependency to run the integration tests."
	for _, chunk := range chunks(text, 18) {
		sess.Ephemeral(proto.StreamDeltaBody{
			Strand: "main", Op: op, Kind: proto.DeltaText, Text: chunk,
		})
		d.pause()
	}

	d.mu.Lock()
	d.callID = fmt.Sprintf("call-%d", d.opN)
	callID := d.callID
	d.mu.Unlock()
	sess.Ephemeral(proto.StreamDeltaBody{
		Strand: "main", Op: op, Kind: proto.DeltaToolCall,
		CallID: callID, ToolName: "bash",
		ArgumentsFragment: `{"command":"npm install`,
	})
	d.pause()

	entryID := fmt.Sprintf("demo-a-%d", d.opN)
	sess.AppendEntry("main", AssistantEntry(entryID, "toolUse", SmallUsage(1400, 260),
		ThinkingBlock(thinking),
		TextBlock(text),
		ToolCallBlock(callID, "bash", map[string]any{"command": "npm install left-pad"}),
	))
	sess.AddUsage("main", op, SmallUsage(1400, 260))

	sess.SetPhase("main", op, proto.PhaseTools)
	sess.Broadcast(proto.EventOpTransition, proto.OpTransitionBody{
		Op: op, Strand: "main", Phase: proto.PhaseTools,
	})
	d.pause()

	escID := fmt.Sprintf("esc-%d", d.opN)
	d.mu.Lock()
	d.pending = escID
	d.mu.Unlock()
	sess.RaiseEscalation(proto.EscalationBody{
		EscalationID: escID,
		Op:           op,
		Strand:       "main",
		// What the approval would actually authorize, as the gateway
		// carries it: the tool, a digest of its effective arguments,
		// and a bounded rendering of them. The preview here carries an
		// ESC sequence on purpose — the demo is where the overlay's
		// sanitiser is visible, and a demo that only ever shows benign
		// arguments demonstrates the wrong thing.
		Tool:    "bash",
		Action:  "9f2c1a7b4e0d63859ac41d2f7b6e8035",
		Preview: "{\"command\":\"npm install left-pad\x1b[2J\x1b[1;1Hloom: nothing to approve\"}",
		Asked:   1,
		Denial: &proto.Denial{
			Reason: "connect to registry.npmjs.org:443 blocked by policy",
			Source: proto.DenialPolicy,
			Wanted: []proto.Grant{{
				Type: proto.GrantNetwork,
				Network: &proto.Network{
					Mode:  proto.NetworkProxy,
					Allow: []string{"registry.npmjs.org"},
					Proxy: "127.0.0.1:3128",
				},
			}},
		},
	})
}

// playApproved settles the tool under the widened policy and finishes
// the run.
func (d *demoScript) playApproved() {
	d.mu.Lock()
	op, callID, n := d.liveOp, d.callID, d.opN
	d.mu.Unlock()
	sess := d.sess
	d.pause()
	sess.AppendEntry("main", ToolResultEntry(
		fmt.Sprintf("demo-t-%d", n), callID, "bash",
		"added 1 package in 412ms", 0,
	))
	d.pause()
	d.finishRun(op, n, "Dependency installed and the integration tests pass. The retry lands in `internal/retry` with a **3 attempt** cap.", proto.ResultDone)
}

// playDenied settles the tool as refused and finishes the run.
func (d *demoScript) playDenied() {
	d.mu.Lock()
	op, callID, n := d.liveOp, d.callID, d.opN
	d.mu.Unlock()
	sess := d.sess
	d.pause()
	sess.AppendEntry("main", ToolResultEntry(
		fmt.Sprintf("demo-t-%d", n), callID, "bash",
		"npm install refused: network to registry.npmjs.org denied by policy", 1,
	))
	d.pause()
	d.finishRun(op, n, "Understood — skipping the dependency. The retry is in place; run the integration tests once network access is settled.", proto.ResultDone)
}

func (d *demoScript) finishRun(op string, n int, closing, status string) {
	sess := d.sess
	sess.SetPhase("main", op, proto.PhaseAssistant)
	sess.Broadcast(proto.EventOpTransition, proto.OpTransitionBody{
		Op: op, Strand: "main", Phase: proto.PhaseAssistant,
	})
	for _, chunk := range chunks(closing, 20) {
		sess.Ephemeral(proto.StreamDeltaBody{
			Strand: "main", Op: op, Kind: proto.DeltaText, Text: chunk,
		})
		d.pause()
	}
	sess.AppendEntry("main", AssistantEntry(
		fmt.Sprintf("demo-f-%d", n), "stop", SmallUsage(600, 140), TextBlock(closing),
	))
	sess.AddUsage("main", op, SmallUsage(600, 140))
	sess.SetPhase("main", op, "")
	sess.Broadcast(proto.EventOpTransition, proto.OpTransitionBody{
		Op: op, Strand: "main", Phase: proto.PhaseDone,
	})
	sess.Broadcast(proto.EventStrandResult, proto.StrandResultBody{
		Strand: "main", Op: op, Status: status,
	})
	d.mu.Lock()
	d.liveOp = ""
	d.mu.Unlock()
}

// chunks splits s into n-rune pieces, preserving everything.
func chunks(s string, n int) []string {
	runes := []rune(s)
	var out []string
	var b strings.Builder
	for i, r := range runes {
		b.WriteRune(r)
		if (i+1)%n == 0 || i == len(runes)-1 {
			out = append(out, b.String())
			b.Reset()
		}
	}
	return out
}
