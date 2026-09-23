package main

import (
	"context"
	"errors"
	"flag"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"sync"
	"time"
)

type server struct {
	profile string
	lock    *os.File
	store   *profileStore
	auth    *authClient
	request *requestClient
	writer  *frameWriter
	mu      sync.Mutex
	active  map[string]context.CancelFunc
	wg      sync.WaitGroup
}

func (s *server) send(e event) { _ = s.writer.send(e) }

func (s *server) fail(id, code string) { s.send(event{ID: id, Event: "error", Code: code}) }

func classify(err error) string {
	switch {
	case errors.Is(err, errNotLoggedIn):
		return "not_logged_in"
	case errors.Is(err, errAccountMismatch):
		return "account_mismatch"
	case errors.Is(err, errRefreshFailed):
		return "refresh_failed"
	case errors.Is(err, errCredentialUnavailable):
		return "credential_unavailable"
	case errors.Is(err, errModelUnavailable):
		return "model_unavailable"
	case errors.Is(err, errInvalidRequest):
		return "invalid_request"
	case errors.Is(err, errRequestTransport):
		return "request_transport_failed"
	default:
		return "request_transport_failed"
	}
}

func (s *server) finish(id string) {
	s.mu.Lock()
	delete(s.active, id)
	s.mu.Unlock()
	s.wg.Done()
}

func (s *server) asyncComplete(id string, ctx context.Context) {
	if ctx.Err() != nil {
		s.send(event{ID: id, Event: "cancel_ack"})
	} else {
		s.send(event{ID: id, Event: "end"})
	}
}

func (s *server) start(id string, work func(context.Context), drained func(context.Context)) {
	s.mu.Lock()
	if _, exists := s.active[id]; exists {
		s.mu.Unlock()
		s.fail(id, "duplicate_id")
		return
	}
	ctx, cancel := context.WithCancel(context.Background())
	s.active[id] = cancel
	s.wg.Add(1)
	s.mu.Unlock()
	go func() {
		work(ctx)
		if drained != nil {
			drained(ctx)
		}
		s.finish(id)
		cancel()
	}()
}

func (s *server) cancel(id string) {
	s.mu.Lock()
	cancel := s.active[id]
	s.mu.Unlock()
	if cancel != nil {
		cancel()
	}
}

func (s *server) handle(c command) {
	if c.V != 1 || c.ID == "" || len(c.ID) > 128 || c.Profile != s.profile {
		s.fail(c.ID, "invalid_command")
		s.send(event{ID: c.ID, Event: "end"})
		return
	}
	switch c.Cmd {
	case "status":
		cred, err := s.store.load()
		if err != nil {
			if errors.Is(err, os.ErrNotExist) {
				s.send(event{ID: c.ID, Event: "status", Code: "logged_out"})
			} else {
				s.fail(c.ID, "credential_unavailable")
			}
			s.send(event{ID: c.ID, Event: "end"})
			return
		}
		s.send(event{ID: c.ID, Event: "status", Code: "logged_in", Plan: cred.Plan})
		s.send(event{ID: c.ID, Event: "end"})
	case "logout":
		s.mu.Lock()
		for _, cancel := range s.active {
			cancel()
		}
		s.mu.Unlock()
		s.wg.Wait()
		if err := s.store.remove(); err != nil {
			s.fail(c.ID, "logout_failed")
			s.send(event{ID: c.ID, Event: "end"})
			return
		}
		s.send(event{ID: c.ID, Event: "logout_complete"})
		s.send(event{ID: c.ID, Event: "end"})
	case "cancel":
		s.cancel(c.ID)
	case "login_device":
		s.start(c.ID, func(ctx context.Context) {
			err := s.auth.loginDevice(ctx, func(e event) { e.ID = c.ID; s.send(e) })
			if err != nil && ctx.Err() == nil {
				code := "login_failed"
				if errors.Is(err, errAccountMismatch) {
					code = "account_mismatch"
				}
				s.fail(c.ID, code)
			}
		}, func(ctx context.Context) { s.asyncComplete(c.ID, ctx) })
	case "login_browser":
		s.start(c.ID, func(ctx context.Context) {
			err := s.auth.loginBrowser(ctx, func(e event) { e.ID = c.ID; s.send(e) })
			if err != nil && ctx.Err() == nil {
				code := "login_failed"
				if errors.Is(err, errAccountMismatch) {
					code = "account_mismatch"
				}
				s.fail(c.ID, code)
			}
		}, func(ctx context.Context) { s.asyncComplete(c.ID, ctx) })
	case "request":
		s.start(c.ID, func(ctx context.Context) {
			err := s.request.stream(ctx, c.BodyB64, func(e event) { e.ID = c.ID; s.send(e) })
			if err != nil {
				if ctx.Err() == nil {
					s.fail(c.ID, classify(err))
				}
			}
		}, func(ctx context.Context) { s.asyncComplete(c.ID, ctx) })
	case "models":
		s.start(c.ID, func(ctx context.Context) {
			models, err := s.request.models(ctx)
			if err != nil {
				s.fail(c.ID, classify(err))
				return
			}
			s.send(event{ID: c.ID, Event: "models", Models: &models})
		}, func(ctx context.Context) { s.asyncComplete(c.ID, ctx) })
	default:
		s.fail(c.ID, "unknown_command")
		s.send(event{ID: c.ID, Event: "end"})
	}
}

func (s *server) run(input io.Reader) error {
	for {
		c, err := readFrame(input)
		if err != nil {
			s.mu.Lock()
			for _, cancel := range s.active {
				cancel()
			}
			s.mu.Unlock()
			s.wg.Wait()
			if err == io.EOF {
				return nil
			}
			return err
		}
		s.handle(c)
	}
}

func newServer(profile, dir string, writer io.Writer, authBase, responseURL string, client *http.Client) (*server, error) {
	store, err := newProfileStore(dir, profile)
	if err != nil {
		return nil, err
	}
	lock, err := acquireProfileLock(dir, profile)
	if err != nil {
		return nil, err
	}
	auth := &authClient{http: client, base: authBase, store: store}
	return &server{profile: profile, lock: lock, store: store, auth: auth, request: &requestClient{http: client, url: responseURL, auth: auth}, writer: &frameWriter{w: writer}, active: make(map[string]context.CancelFunc)}, nil
}

func newHTTPClient() *http.Client {
	return &http.Client{
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
		Transport:     &http.Transport{ResponseHeaderTimeout: 30 * time.Second, IdleConnTimeout: 30 * time.Second},
	}
}

func main() {
	profile := flag.String("profile", "", "dedicated Loom subscription profile name")
	flag.Parse()
	if *profile == "" || flag.NArg() != 0 {
		os.Exit(2)
	}
	dir, err := os.UserConfigDir()
	if err != nil {
		os.Exit(1)
	}
	client := newHTTPClient()
	s, err := newServer(*profile, filepath.Join(dir, "loom", "codex-subscription"), os.Stdout, "https://auth.openai.com", backendURL, client)
	if err != nil {
		os.Exit(1)
	}
	defer s.lock.Close()
	if s.run(os.Stdin) != nil {
		os.Exit(1)
	}
}
