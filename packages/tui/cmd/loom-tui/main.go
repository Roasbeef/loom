// Command loom-tui is the terminal client for a Loom session: a thin
// client over the ClientGateway websocket protocol (spec Part 1.6).
//
//	loom-tui --addr ws://127.0.0.1:7777/v1/ws --session my-session
//	loom-tui --demo   # in-process fake gateway with a canned session
package main

import (
	"context"
	"flag"
	"fmt"
	"net/http/httptest"
	"os"
	"os/signal"
	"syscall"
	"time"

	tea "github.com/charmbracelet/bubbletea"

	"github.com/roasbeef/loom/tui/internal/client"
	"github.com/roasbeef/loom/tui/internal/fake"
	"github.com/roasbeef/loom/tui/internal/ui"
)

func main() {
	if err := run(); err != nil {
		fmt.Fprintln(os.Stderr, "loom-tui:", err)
		os.Exit(1)
	}
}

func run() error {
	var (
		addr    = flag.String("addr", "", "gateway websocket URL (e.g. ws://127.0.0.1:7777/v1/ws)")
		session = flag.String("session", "", "session id to attach to")
		token   = flag.String("token", "", "bearer token (omit for a local gateway)")
		demo    = flag.Bool("demo", false, "run against an in-process fake gateway with a canned session")
	)
	flag.Parse()

	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()

	if *demo {
		server := fake.NewServer("")
		fake.DemoSession(server, 60*time.Millisecond)
		ts := httptest.NewServer(server.Handler())
		defer ts.Close()
		*addr = "ws" + ts.URL[len("http"):] + "/v1/ws"
		*session = "demo"
		*token = ""
	}
	if *addr == "" || *session == "" {
		return fmt.Errorf("--addr and --session are required (or use --demo)")
	}

	c := client.New(client.Config{
		Addr:    *addr,
		Session: *session,
		Token:   *token,
	})
	clientDone := make(chan error, 1)
	go func() { clientDone <- c.Run(ctx) }()

	program := tea.NewProgram(
		ui.New(ui.Config{Session: *session, Sender: c}),
		tea.WithAltScreen(),
		tea.WithContext(ctx),
	)

	// Pump connection messages into the program until the client stops
	// (its channel closes when Run returns).
	go func() {
		for msg := range c.Messages() {
			program.Send(msg)
		}
	}()

	_, err := program.Run()
	cancel()
	<-clientDone
	if err != nil && ctx.Err() == nil {
		return fmt.Errorf("ui: %w", err)
	}
	return nil
}
