package ui

import (
	"context"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/roasbeef/loom/tui/internal/client"
	"github.com/roasbeef/loom/tui/internal/fake"
	"github.com/roasbeef/loom/tui/internal/proto"
)

// TestDemoHeadless runs the canned demo end to end without a
// terminal: real fake gateway, real websocket client, and the model
// driven directly (the renderer is the only thing missing). It follows
// the whole arc — prompt, streaming, tool call, escalation approval,
// settled result — and asserts the final rendered transcript.
func TestDemoHeadless(t *testing.T) {
	server := fake.NewServer("")
	fake.DemoSession(server, time.Millisecond)
	ts := httptest.NewServer(server.Handler())
	defer ts.Close()

	c := client.New(client.Config{
		Addr: "ws" + strings.TrimPrefix(ts.URL, "http") + "/v1/ws", Session: "demo",
		BackoffBase: 5 * time.Millisecond,
	})
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- c.Run(ctx) }()
	defer func() {
		cancel()
		<-done
	}()

	m := New(Config{Session: "demo", Sender: c})
	m = apply(t, m, tea.WindowSizeMsg{Width: 100, Height: 40})

	const (
		stageAwaitSnapshot = iota
		stageAwaitEscalation
		stageAwaitResult
		stageDone
	)
	stage := stageAwaitSnapshot
	sawStreaming := false
	sawApprovalPrompt := false

	deadline := time.After(30 * time.Second)
	for stage != stageDone {
		select {
		case msg, ok := <-c.Messages():
			if !ok {
				t.Fatal("client stopped early")
			}
			next, _ := m.Update(msg)
			m = next.(Model)

			if _, isDelta := msg.(client.StreamDeltaMsg); isDelta {
				// Live deltas must show up in the rendered transcript
				// before the settled entry lands.
				if strings.Contains(m.renderTranscript(), "streaming") {
					sawStreaming = true
				}
			}

			switch stage {
			case stageAwaitSnapshot:
				if snap, ok := msg.(client.SnapshotMsg); ok && snap.Body.Mode == proto.SnapshotFull {
					// The snapshot carries the canned history.
					if got := m.renderTranscript(); !strings.Contains(got, "no retry policy") {
						t.Fatalf("history missing from snapshot transcript:\n%s", got)
					}
					m = typeText(t, m, "add the retry and install the dependency")
					m = apply(t, m, key("enter"))
					stage = stageAwaitEscalation
				}
			case stageAwaitEscalation:
				if esc, ok := msg.(client.EscalationMsg); ok && esc.Body.Status == proto.EscalationPending {
					view := m.View()
					if !strings.Contains(view, "wants: network to registry.npmjs.org") {
						t.Fatalf("approval prompt missing the policy diff:\n%s", view)
					}
					sawApprovalPrompt = true
					m = apply(t, m, key("y"))
					stage = stageAwaitResult
				}
			case stageAwaitResult:
				if res, ok := msg.(client.StrandResultMsg); ok {
					if res.Body.Status != proto.ResultDone {
						t.Fatalf("demo run did not finish cleanly: %+v", res.Body)
					}
					stage = stageDone
				}
			}
		case <-deadline:
			t.Fatalf("demo stalled at stage %d", stage)
		}
	}

	// Drain stragglers so the final transcript is settled.
	drain := time.After(200 * time.Millisecond)
	for {
		select {
		case msg := <-c.Messages():
			next, _ := m.Update(msg)
			m = next.(Model)
			continue
		case <-drain:
		}
		break
	}

	if !sawStreaming {
		t.Error("never saw live streaming output")
	}
	if !sawApprovalPrompt {
		t.Error("never saw the approval prompt")
	}

	transcript := m.renderTranscript()
	for _, want := range []string{
		"add the retry and install the dependency", // the user prompt entry
		"npm install left-pad",                     // the tool call
		"exit 0",                                   // tool result badge
		"added 1 package",                          // tool output
		"Dependency installed",                     // closing assistant text
	} {
		if !strings.Contains(transcript, want) {
			t.Errorf("final transcript missing %q:\n%s", want, transcript)
		}
	}
	if m.overlayActive() {
		t.Error("approval prompt still up after the decision")
	}
	if view := m.View(); !strings.Contains(view, "connected") {
		t.Errorf("status bar not showing connection state:\n%s", view)
	}
	if m.usage.TotalTokens == 0 {
		t.Error("usage never accumulated")
	}
}
