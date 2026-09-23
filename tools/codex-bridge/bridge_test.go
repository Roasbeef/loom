package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"os/exec"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func fakeToken(account string) string {
	claims := map[string]any{authClaim: map[string]string{"chatgpt_account_id": account, "chatgpt_plan_type": "pro"}}
	buf, _ := json.Marshal(claims)
	return "x." + base64.RawURLEncoding.EncodeToString(buf) + ".x"
}

func testCredential(account string) credential {
	return credential{Access: fakeToken(account), Refresh: "refresh-secret", Expires: time.Now().Add(time.Hour), AccountID: account, Plan: "pro"}
}

func TestFrameBoundsAndNoCredentialFields(t *testing.T) {
	var output bytes.Buffer
	w := &frameWriter{w: &output}
	if err := w.send(event{ID: "one", Event: "status", Code: "logged_in", Plan: "pro"}); err != nil {
		t.Fatal(err)
	}
	buf := output.Bytes()
	if int(binary.BigEndian.Uint32(buf[:4])) != len(buf)-4 || bytes.Contains(buf, []byte("refresh-secret")) || bytes.Contains(buf, []byte("account_id")) {
		t.Fatalf("unexpected output frame: %s", buf[4:])
	}
	var tooBig [4]byte
	binary.BigEndian.PutUint32(tooBig[:], maxFrame+1)
	if _, err := readFrame(bytes.NewReader(tooBig[:])); err == nil {
		t.Fatal("oversized input accepted")
	}
}

func TestRequestErrorEndsAfterWorkerCleanup(t *testing.T) {
	reader, writer := io.Pipe()
	timer := time.AfterFunc(3*time.Second, func() { reader.Close() })
	defer timer.Stop()
	defer reader.Close()
	defer writer.Close()
	s := &server{
		profile: "personal",
		request: &requestClient{},
		writer:  &frameWriter{w: writer},
		active:  make(map[string]context.CancelFunc),
	}
	s.handle(command{V: 1, ID: "bad-request", Cmd: "request", Profile: "personal", BodyB64: "not base64"})
	for _, expected := range []string{"error", "end"} {
		var length [4]byte
		if _, err := io.ReadFull(reader, length[:]); err != nil {
			t.Fatal(err)
		}
		body := make([]byte, binary.BigEndian.Uint32(length[:]))
		if _, err := io.ReadFull(reader, body); err != nil {
			t.Fatal(err)
		}
		var got event
		if err := json.Unmarshal(body, &got); err != nil {
			t.Fatal(err)
		}
		if got.Event != expected || got.ID != "bad-request" {
			t.Fatalf("event = %+v, want %s for bad-request", got, expected)
		}
		if expected == "error" && got.Code != "invalid_request" {
			t.Fatalf("error code = %s, want invalid_request", got.Code)
		}
	}
	s.mu.Lock()
	_, active := s.active["bad-request"]
	s.mu.Unlock()
	if active {
		t.Fatal("terminal end preceded worker cleanup")
	}
}

func TestCancellationProducesOneTerminal(t *testing.T) {
	var output bytes.Buffer
	s := &server{
		writer: &frameWriter{w: &output},
		active: make(map[string]context.CancelFunc),
	}
	workDone := make(chan struct{})
	releaseTerminal := make(chan struct{})
	s.start("cancelled", func(context.Context) { close(workDone) }, func(ctx context.Context) {
		<-releaseTerminal
		s.asyncComplete("cancelled", ctx)
	})
	<-workDone
	s.cancel("cancelled")
	close(releaseTerminal)
	s.wg.Wait()
	s.cancel("cancelled")
	if !bytes.Contains(output.Bytes(), []byte(`"cancel_ack"`)) || bytes.Contains(output.Bytes(), []byte(`"end"`)) {
		t.Fatalf("cancelled request emitted the wrong terminal: %s", output.Bytes())
	}
	firstLength := output.Len()
	s.cancel("cancelled")
	if output.Len() != firstLength {
		t.Fatal("late cancellation emitted a second terminal")
	}

	output.Reset()
	s.start("completed", func(context.Context) {}, func(ctx context.Context) {
		s.asyncComplete("completed", ctx)
	})
	s.wg.Wait()
	s.cancel("completed")
	if !bytes.Contains(output.Bytes(), []byte(`"end"`)) || bytes.Contains(output.Bytes(), []byte(`"cancel_ack"`)) {
		t.Fatalf("completed request emitted the wrong terminal: %s", output.Bytes())
	}
}

func TestProfileValidationAndPermissions(t *testing.T) {
	if _, err := newProfileStore(t.TempDir(), "../escape"); err == nil {
		t.Fatal("profile traversal accepted")
	}
	p, err := newProfileStore(t.TempDir()+"/private", "personal")
	if err != nil {
		t.Fatal(err)
	}
	if err := p.save(testCredential("acct-one")); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(p.path())
	if err != nil || info.Mode().Perm() != 0600 {
		t.Fatalf("credential mode: %v %v", info, err)
	}
	if err := os.Chmod(p.path(), 0644); err != nil {
		t.Fatal(err)
	}
	if _, err := p.load(); err == nil {
		t.Fatal("read permissive credential file")
	}
	var output bytes.Buffer
	s := &server{profile: "personal", store: p, writer: &frameWriter{w: &output}}
	s.handle(command{V: 1, ID: "status", Cmd: "status", Profile: "personal"})
	if !bytes.Contains(output.Bytes(), []byte(`"credential_unavailable"`)) || bytes.Contains(output.Bytes(), []byte(`"logged_out"`)) {
		t.Fatal("unsafe credential file was reported as logged out")
	}
}

func TestLoginCannotSwitchAccountWithoutLogout(t *testing.T) {
	p, _ := newProfileStore(t.TempDir()+"/private", "personal")
	old := testCredential("acct-one")
	if err := p.saveLogin(old); err != nil {
		t.Fatal(err)
	}
	if err := p.saveLogin(testCredential("acct-two")); err == nil {
		t.Fatal("account switch accepted without logout")
	}
	current, err := p.load()
	if err != nil || current.AccountID != old.AccountID || current.Refresh != old.Refresh {
		t.Fatal("failed account switch changed credentials")
	}
	if err := p.remove(); err != nil {
		t.Fatal(err)
	}
	if err := p.saveLogin(testCredential("acct-two")); err != nil {
		t.Fatal("explicit logout did not permit switch:", err)
	}
}

func TestProfileLockChild(t *testing.T) {
	if os.Getenv("CODEX_BRIDGE_LOCK_CHILD") != "1" {
		return
	}
	lock, err := acquireProfileLock(os.Getenv("CODEX_BRIDGE_LOCK_DIR"), "shared")
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(3)
	}
	defer lock.Close()
	fmt.Print("ready\n")
	_, _ = io.Copy(io.Discard, os.Stdin)
}

func TestProfileLockAcrossProcesses(t *testing.T) {
	dir := t.TempDir() + "/private"
	child := exec.Command(os.Args[0], "-test.run=TestProfileLockChild")
	child.Env = append(os.Environ(), "CODEX_BRIDGE_LOCK_CHILD=1", "CODEX_BRIDGE_LOCK_DIR="+dir)
	stdin, err := child.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	stdout, err := child.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	var childError bytes.Buffer
	child.Stderr = &childError
	if err := child.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() { stdin.Close(); _ = child.Wait() }()
	var ready [6]byte
	if _, err := io.ReadFull(stdout, ready[:]); err != nil || string(ready[:]) != "ready\n" {
		t.Fatalf("child lock readiness: %q %v; child stderr: %s", ready, err, childError.String())
	}
	if lock, err := acquireProfileLock(dir, "shared"); err == nil {
		lock.Close()
		t.Fatal("second helper acquired owned profile")
	}
}

func TestRefreshRejectsAccountChange(t *testing.T) {
	p, _ := newProfileStore(t.TempDir()+"/private", "personal")
	old := testCredential("acct-one")
	old.Expires = time.Now().Add(-time.Minute)
	if err := p.save(old); err != nil {
		t.Fatal(err)
	}
	authServer := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/oauth/token" {
			t.Errorf("unexpected path: %s", r.URL.Path)
		}
		fmt.Fprintf(w, `{"access_token":%q,"refresh_token":"rotated-secret","expires_in":3600}`, fakeToken("acct-two"))
	}))
	defer authServer.Close()
	a := &authClient{http: authServer.Client(), base: authServer.URL, store: p}
	if _, err := a.current(context.Background(), false); err == nil {
		t.Fatal("cross-account refresh accepted")
	}
	after, err := p.load()
	if err != nil || after.Refresh != old.Refresh || after.AccountID != old.AccountID {
		t.Fatalf("old credentials overwritten: %+v %v", after, err)
	}
}

func TestConcurrentExpiredRequestsRefreshOnce(t *testing.T) {
	p, _ := newProfileStore(t.TempDir()+"/private", "personal")
	c := testCredential("acct-one")
	c.Expires = time.Now().Add(-time.Minute)
	if err := p.save(c); err != nil {
		t.Fatal(err)
	}
	var refreshes atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		refreshes.Add(1)
		time.Sleep(20 * time.Millisecond)
		fmt.Fprintf(w, `{"access_token":%q,"refresh_token":"rotated-secret","expires_in":3600}`, fakeToken("acct-one"))
	}))
	defer server.Close()
	a := &authClient{http: server.Client(), base: server.URL, store: p}
	const callers = 12
	start := make(chan struct{})
	var wg sync.WaitGroup
	errors := make(chan error, callers)
	for i := 0; i < callers; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			<-start
			got, err := a.current(context.Background(), false)
			if err == nil && got.Refresh != "rotated-secret" {
				err = fmt.Errorf("received stale refresh token")
			}
			errors <- err
		}()
	}
	close(start)
	wg.Wait()
	close(errors)
	for err := range errors {
		if err != nil {
			t.Fatal(err)
		}
	}
	if refreshes.Load() != 1 {
		t.Fatalf("expected one refresh, got %d", refreshes.Load())
	}
}

func TestRequestDiscoversAccountAndReplaysOne401(t *testing.T) {
	var posts atomic.Int32
	var refreshes atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/backend-api/codex/models":
			if r.Header.Get("chatgpt-account-id") != "acct-one" || r.URL.Query().Get("client_version") != clientVersion {
				t.Error("model discovery lost account/version binding")
			}
			io.WriteString(w, `{"models":[{"slug":"gpt-6-sol","context_window":200000,"supported_reasoning_levels":[{"effort":"high"}]}]}`)
		case "/backend-api/codex/responses":
			if r.Header.Get("chatgpt-account-id") != "acct-one" || r.Header.Get("x-codex-routing-hint") != "model=gpt-6-sol" || r.Header.Get("OpenAI-Beta") != "responses=experimental" {
				t.Error("missing bound Codex headers")
			}
			if posts.Add(1) == 1 {
				w.WriteHeader(401)
				return
			}
			w.Header().Set("Content-Type", "text/event-stream")
			io.WriteString(w, "event: response.completed\ndata: {}\n\n")
		case "/oauth/token":
			refreshes.Add(1)
			fmt.Fprintf(w, `{"access_token":%q,"refresh_token":"rotated-secret","expires_in":3600}`, fakeToken("acct-one"))
		default:
			t.Errorf("unexpected route %s", r.URL.Path)
			w.WriteHeader(404)
		}
	}))
	defer server.Close()
	p, _ := newProfileStore(t.TempDir()+"/private", "personal")
	if err := p.save(testCredential("acct-one")); err != nil {
		t.Fatal(err)
	}
	auth := &authClient{http: server.Client(), base: server.URL, store: p}
	r := &requestClient{http: server.Client(), url: server.URL + "/backend-api/codex/responses", auth: auth}
	body := base64.StdEncoding.EncodeToString([]byte(`{"model":"gpt-6-sol","stream":true,"store":false,"input":[]}`))
	var events []event
	if err := r.stream(context.Background(), body, func(e event) { events = append(events, e) }); err != nil {
		t.Fatal(err)
	}
	if posts.Load() != 2 || refreshes.Load() != 1 || len(events) != 2 || events[0].Event != "http_status" || events[1].Event != "chunk" {
		t.Fatalf("unexpected exchange: posts=%d refreshes=%d events=%+v", posts.Load(), refreshes.Load(), events)
	}
	encoded, _ := json.Marshal(events)
	if bytes.Contains(encoded, []byte("refresh-secret")) || bytes.Contains(encoded, []byte("acct-one")) {
		t.Fatal("credential material entered response protocol")
	}
}

func TestUnavailableModelNeverPosts(t *testing.T) {
	var posted atomic.Bool
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodPost {
			posted.Store(true)
		}
		io.WriteString(w, `{"models":[{"slug":"gpt-6-luna"}]}`)
	}))
	defer server.Close()
	p, _ := newProfileStore(t.TempDir()+"/private", "personal")
	_ = p.save(testCredential("acct-one"))
	auth := &authClient{http: server.Client(), base: server.URL, store: p}
	r := &requestClient{http: server.Client(), url: server.URL + "/backend-api/codex/responses", auth: auth}
	body := base64.StdEncoding.EncodeToString([]byte(`{"model":"gpt-6-astra","stream":true,"store":false}`))
	err := r.stream(context.Background(), body, func(event) {})
	if !errors.Is(err, errModelUnavailable) || posted.Load() {
		t.Fatalf("model admission: err=%v posted=%v", err, posted.Load())
	}
}

func TestOneReplayBudgetAcrossDiscoveryAndInference(t *testing.T) {
	var models atomic.Int32
	var posts atomic.Int32
	var refreshes atomic.Int32
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/backend-api/codex/models":
			if models.Add(1) == 1 {
				w.WriteHeader(401)
				return
			}
			io.WriteString(w, `{"models":[{"slug":"gpt-6-sol"}]}`)
		case "/backend-api/codex/responses":
			posts.Add(1)
			w.WriteHeader(401)
		case "/oauth/token":
			refreshes.Add(1)
			fmt.Fprintf(w, `{"access_token":%q,"refresh_token":"rotated-secret","expires_in":3600}`, fakeToken("acct-one"))
		default:
			w.WriteHeader(404)
		}
	}))
	defer server.Close()
	p, _ := newProfileStore(t.TempDir()+"/private", "personal")
	_ = p.save(testCredential("acct-one"))
	auth := &authClient{http: server.Client(), base: server.URL, store: p}
	r := &requestClient{http: server.Client(), url: server.URL + "/backend-api/codex/responses", auth: auth}
	body := base64.StdEncoding.EncodeToString([]byte(`{"model":"gpt-6-sol","stream":true,"store":false}`))
	err := r.stream(context.Background(), body, func(event) {})
	if !errors.Is(err, errRefreshFailed) || models.Load() != 2 || posts.Load() != 1 || refreshes.Load() != 1 {
		t.Fatalf("replay bound broken: err=%v models=%d posts=%d refreshes=%d", err, models.Load(), posts.Load(), refreshes.Load())
	}
}

func TestModelsRejectsHiddenAndMalformed(t *testing.T) {
	models, err := parseModels(strings.NewReader(`{"models":[{"slug":"gpt-6-sol","visibility":"hidden"},{"slug":"gpt-6-astra","max_context_window":1000000}]}`))
	if err != nil || len(models) != 1 || models[0].ID != "gpt-6-astra" || models[0].ContextWindow != 1000000 {
		t.Fatalf("models=%+v err=%v", models, err)
	}
	if _, err := parseModels(strings.NewReader(`{"unexpected":[]}`)); err == nil {
		t.Fatal("missing model list accepted")
	}
}

func TestProductionHTTPClientRefusesRedirect(t *testing.T) {
	var redirected atomic.Bool
	destination := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		redirected.Store(true)
	}))
	defer destination.Close()
	source := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Location", destination.URL)
		w.WriteHeader(http.StatusFound)
	}))
	defer source.Close()
	req, _ := http.NewRequest(http.MethodGet, source.URL, nil)
	req.Header.Set("Authorization", "Bearer canary-secret")
	resp, err := newHTTPClient().Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusFound || redirected.Load() {
		t.Fatal("credentialed redirect was followed")
	}
}

func TestBrowserPKCECallback(t *testing.T) {
	var expectedChallenge atomic.Value
	expectedChallenge.Store("")
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/oauth/token" {
			t.Errorf("unexpected auth path %s", r.URL.Path)
			w.WriteHeader(404)
			return
		}
		if err := r.ParseForm(); err != nil {
			t.Error(err)
		}
		verifier := r.PostForm.Get("code_verifier")
		challenge := sha256.Sum256([]byte(verifier))
		if base64.RawURLEncoding.EncodeToString(challenge[:]) != expectedChallenge.Load().(string) || r.PostForm.Get("redirect_uri") != browserRedirect || r.PostForm.Get("code") != "test-code" {
			t.Error("browser callback was not bound to PKCE and fixed redirect")
		}
		fmt.Fprintf(w, `{"access_token":%q,"refresh_token":"refresh-secret","expires_in":3600}`, fakeToken("acct-one"))
	}))
	defer server.Close()
	p, _ := newProfileStore(t.TempDir()+"/private", "personal")
	a := &authClient{http: server.Client(), base: server.URL, store: p}
	instructions := make(chan event, 2)
	result := make(chan error, 1)
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go func() { result <- a.loginBrowser(ctx, func(e event) { instructions <- e }) }()
	var first event
	select {
	case first = <-instructions:
	case err := <-result:
		if err != nil && strings.Contains(err.Error(), "port unavailable") {
			t.Skip("local OAuth callback port is occupied")
		}
		t.Fatalf("login failed before instructions: %v", err)
	case <-time.After(5 * time.Second):
		t.Fatal("browser instructions not emitted")
	}
	parsed, err := url.Parse(first.URL)
	if err != nil {
		t.Fatal(err)
	}
	expectedChallenge.Store(parsed.Query().Get("code_challenge"))
	state := parsed.Query().Get("state")
	if state == "" || expectedChallenge.Load().(string) == "" {
		t.Fatal("missing state or PKCE challenge")
	}
	bad, err := http.Get(browserRedirect + "?state=wrong&code=test-code")
	if err != nil || bad.StatusCode != 400 {
		t.Fatalf("bad state accepted: %v %v", bad, err)
	}
	bad.Body.Close()
	good, err := http.Get(browserRedirect + "?state=" + url.QueryEscape(state) + "&code=test-code")
	if err != nil || good.StatusCode != 200 {
		t.Fatalf("valid callback failed: %v %v", good, err)
	}
	good.Body.Close()
	if err := <-result; err != nil {
		t.Fatal(err)
	}
	complete := <-instructions
	if complete.Event != "login_complete" || complete.Plan != "pro" {
		t.Fatalf("unexpected login completion: %+v", complete)
	}
	if _, err := p.load(); err != nil {
		t.Fatal(err)
	}
}
