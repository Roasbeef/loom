package ghproxy

import (
	"bufio"
	"bytes"
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"testing"
	"time"
)

const realToken = "ghp_RealTokenValue0123456789abcdef"

// syncBuffer is a log sink that is safe to read while the proxy writes.
type syncBuffer struct {
	mu sync.Mutex
	b  bytes.Buffer
}

func (s *syncBuffer) Write(p []byte) (int, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	return s.b.Write(p)
}

func (s *syncBuffer) String() string {
	s.mu.Lock()
	defer s.mu.Unlock()

	return s.b.String()
}

// seen is what the upstream server received for one request.
type seen struct {
	Method, Host, Path, RawQuery, Body string
	Header                             http.Header
}

// harness is a proxy between a test client and a TLS server that stands in
// for GitHub. The upstream's certificates come from a CA of its own, so the
// client can tell a leaf the proxy minted from one the upstream presented.
type harness struct {
	t        *testing.T
	proxy    *Proxy
	proxySrv *httptest.Server
	upstream *httptest.Server
	upCA     *ca
	logs     *syncBuffer

	mu       sync.Mutex
	requests []seen
}

func newHarness(t *testing.T, mutate func(*Config)) *harness {
	t.Helper()

	h := &harness{t: t, logs: &syncBuffer{}}

	var err error
	h.upCA, err = newCA(time.Hour, nil)
	if err != nil {
		t.Fatal(err)
	}

	h.upstream = httptest.NewUnstartedServer(http.HandlerFunc(h.record))
	h.upstream.TLS = &tls.Config{
		GetCertificate: func(hello *tls.ClientHelloInfo) (*tls.Certificate, error) {
			return h.upCA.leaf(hello.ServerName)
		},
	}
	h.upstream.StartTLS()
	t.Cleanup(h.upstream.Close)

	roots := x509.NewCertPool()
	roots.AddCert(h.upCA.cert)

	cfg := Config{
		Token:         realToken,
		Allow:         []string{"github.com", "api.github.com", "uploads.github.com", "example.com"},
		Inject:        DefaultInjectHosts,
		Logger:        slog.New(slog.NewTextHandler(h.logs, nil)),
		UpstreamRoots: roots,
		Dial: func(ctx context.Context, network, _ string) (net.Conn, error) {
			var d net.Dialer

			return d.DialContext(ctx, network, h.upstream.Listener.Addr().String())
		},
	}
	if mutate != nil {
		mutate(&cfg)
	}

	h.proxy, err = New(cfg)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(h.proxy.Close)

	h.proxySrv = httptest.NewServer(h.proxy)
	t.Cleanup(h.proxySrv.Close)

	return h
}

// record is the upstream handler: it stores the request and answers 200.
func (h *harness) record(w http.ResponseWriter, r *http.Request) {
	body, _ := io.ReadAll(r.Body)

	h.mu.Lock()
	h.requests = append(h.requests, seen{
		Method: r.Method, Host: r.Host, Path: r.URL.Path, RawQuery: r.URL.RawQuery,
		Body: string(body), Header: r.Header.Clone(),
	})
	h.mu.Unlock()

	fmt.Fprint(w, "upstream says hi")
}

func (h *harness) upstreamRequests() []seen {
	h.mu.Lock()
	defer h.mu.Unlock()

	return append([]seen(nil), h.requests...)
}

// client trusts the proxy's CA, as the guest does.
func (h *harness) client() *http.Client {
	return h.clientTrusting(h.proxy.ca.cert)
}

func (h *harness) clientTrusting(root *x509.Certificate) *http.Client {
	pool := x509.NewCertPool()
	pool.AddCert(root)

	proxyURL, _ := url.Parse(h.proxySrv.URL)

	return &http.Client{
		Timeout: 10 * time.Second,
		Transport: &http.Transport{
			Proxy:           http.ProxyURL(proxyURL),
			TLSClientConfig: &tls.Config{RootCAs: pool},
		},
	}
}

// do sends a request and returns the status and body.
func (h *harness) do(c *http.Client, method, target, auth, body string) (int, string) {
	h.t.Helper()

	req, err := http.NewRequest(method, target, strings.NewReader(body))
	if err != nil {
		h.t.Fatal(err)
	}
	if auth != "" {
		req.Header.Set("Authorization", auth)
	}

	resp, err := c.Do(req)
	if err != nil {
		h.t.Fatalf("%s %s: %v", method, target, err)
	}
	defer resp.Body.Close()

	out, _ := io.ReadAll(resp.Body)

	return resp.StatusCode, string(out)
}

// rawConnect opens a connection to the proxy, sends a CONNECT, and returns the
// connection and the status line's code.
func (h *harness) rawConnect(target string) (net.Conn, *bufio.Reader, int) {
	h.t.Helper()

	conn, err := net.Dial("tcp", h.proxySrv.Listener.Addr().String())
	if err != nil {
		h.t.Fatal(err)
	}
	h.t.Cleanup(func() { conn.Close() })

	fmt.Fprintf(conn, "CONNECT %s HTTP/1.1\r\nHost: %s\r\n\r\n", target, target)

	br := bufio.NewReader(conn)
	resp, err := http.ReadResponse(br, nil)
	if err != nil {
		h.t.Fatal(err)
	}

	return conn, br, resp.StatusCode
}

func basic(user, password string) string {
	return "Basic " + base64.StdEncoding.EncodeToString([]byte(user+":"+password))
}

func TestInjectsAuthorizationForm(t *testing.T) {
	h := newHarness(t, nil)
	c := h.client()
	ph := h.proxy.Placeholder()

	cases := []struct {
		name, sent, want string
		injected         bool
	}{
		{
			name: "basic as git sends it",
			sent: basic("x-access-token", ph),
			want: basic("x-access-token", realToken), injected: true,
		},
		{
			name: "basic with the placeholder as username",
			sent: basic(ph, "x-oauth-basic"),
			want: basic(realToken, "x-oauth-basic"), injected: true,
		},
		{name: "token as gh sends it", sent: "token " + ph, want: "token " + realToken, injected: true},
		{name: "bearer as gh sends it", sent: "Bearer " + ph, want: "Bearer " + realToken, injected: true},
		{name: "scheme case is ignored", sent: "bearer " + ph, want: "bearer " + realToken, injected: true},
		{name: "another credential is untouched", sent: "Bearer someone-elses", want: "Bearer someone-elses"},
		{name: "placeholder as a substring is untouched", sent: "Bearer " + ph + "x", want: "Bearer " + ph + "x"},
		{name: "basic with an unrelated password", sent: basic("u", "p"), want: basic("u", "p")},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			before := len(h.upstreamRequests())

			status, _ := h.do(c, http.MethodGet, "https://api.github.com/user", tc.sent, "")
			if status != http.StatusOK {
				t.Fatalf("status %d", status)
			}

			reqs := h.upstreamRequests()
			if len(reqs) != before+1 {
				t.Fatalf("upstream saw %d new requests", len(reqs)-before)
			}

			if got := reqs[before].Header.Get("Authorization"); got != tc.want {
				t.Fatalf("upstream Authorization = %q, want %q", got, tc.want)
			}
		})
	}
}

func TestPlaceholderOutsideAuthorizationIsNotSubstituted(t *testing.T) {
	h := newHarness(t, nil)
	ph := h.proxy.Placeholder()

	req, err := http.NewRequest(http.MethodPost,
		"https://github.com/o/r.git/git-receive-pack?token="+ph, strings.NewReader("body "+ph))
	if err != nil {
		t.Fatal(err)
	}
	req.Header.Set("X-Other", ph)
	req.Header.Set("Authorization", "Bearer "+ph)

	resp, err := h.client().Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()

	got := h.upstreamRequests()[0]
	switch {
	case got.RawQuery != "token="+ph:
		t.Fatalf("query was rewritten: %q", got.RawQuery)

	case got.Body != "body "+ph:
		t.Fatalf("body was rewritten: %q", got.Body)

	case got.Header.Get("X-Other") != ph:
		t.Fatalf("another header was rewritten: %q", got.Header.Get("X-Other"))

	case got.Header.Get("Authorization") != "Bearer "+realToken:
		t.Fatalf("authorization was not injected: %q", got.Header.Get("Authorization"))
	}
}

func TestKeepAliveServesManyRequestsOnOneTunnel(t *testing.T) {
	h := newHarness(t, nil)
	c := h.client()

	for range 3 {
		h.do(c, http.MethodGet, "https://github.com/", "token "+h.proxy.Placeholder(), "")
	}

	if n := len(h.upstreamRequests()); n != 3 {
		t.Fatalf("upstream saw %d requests, want 3", n)
	}

	if n := strings.Count(h.logs.String(), "mode=intercept"); n != 1 {
		t.Fatalf("%d intercepted connections for one keep-alive client, want 1", n)
	}
}

func TestNonInjectionHostIsTunnelledWithItsOwnCertificate(t *testing.T) {
	h := newHarness(t, nil)

	// The client trusts only the upstream's CA. A handshake that succeeds
	// therefore proves the certificate came from the upstream, not the proxy.
	c := h.clientTrusting(h.upCA.cert)
	ph := h.proxy.Placeholder()

	req, _ := http.NewRequest(http.MethodGet, "https://example.com/x", nil)
	req.Header.Set("Authorization", "Bearer "+ph)

	resp, err := c.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()

	issuer := resp.TLS.PeerCertificates[0].Issuer.CommonName
	if issuer != h.upCA.cert.Subject.CommonName {
		t.Fatalf("certificate issued by %q, want the upstream's CA", issuer)
	}

	got := h.upstreamRequests()[0]
	if got.Header.Get("Authorization") != "Bearer "+ph {
		t.Fatalf("a tunnelled request was modified: %q", got.Header.Get("Authorization"))
	}

	if !strings.Contains(h.logs.String(), "mode=tunnel") {
		t.Fatalf("no tunnel line in the log:\n%s", h.logs.String())
	}
}

func TestInterceptedHostIsNotTrustedByTheUpstreamCA(t *testing.T) {
	h := newHarness(t, nil)

	// The converse: an injection host's certificate is the proxy's, so a
	// client that does not trust the proxy CA refuses it.
	c := h.clientTrusting(h.upCA.cert)

	if _, err := c.Get("https://github.com/"); err == nil {
		t.Fatal("handshake with an intercepted host succeeded without the proxy CA")
	}
}

func TestRefusals(t *testing.T) {
	h := newHarness(t, func(c *Config) {
		c.Allow = append(c.Allow, "*.corp.example", "blocked.example")
		c.Deny = []string{"blocked.example", "secret.corp.example"}
	})

	cases := []struct {
		target string
		want   int
	}{
		{"evil.example.org:443", http.StatusForbidden},
		{"github.com:8443", http.StatusForbidden},
		{"github.com", http.StatusForbidden},
		{"127.0.0.1:443", http.StatusForbidden},
		{"blocked.example:443", http.StatusForbidden},
		{"secret.corp.example:443", http.StatusForbidden},
		{"corp.example:443", http.StatusForbidden},
		{"github.com:443", http.StatusOK},
		{"build.corp.example:443", http.StatusOK},
	}

	for _, tc := range cases {
		t.Run(tc.target, func(t *testing.T) {
			_, _, got := h.rawConnect(tc.target)
			if got != tc.want {
				t.Fatalf("CONNECT %s = %d, want %d", tc.target, got, tc.want)
			}
		})
	}
}

func TestInjectionHostOutsideAllowlistIsRefused(t *testing.T) {
	h := newHarness(t, func(c *Config) { c.Allow = []string{"example.com"} })

	if _, _, got := h.rawConnect("github.com:443"); got != http.StatusForbidden {
		t.Fatalf("CONNECT to an injection host the allowlist omits = %d", got)
	}
}

func TestNonConnectIsRefused(t *testing.T) {
	h := newHarness(t, nil)

	resp, err := http.Get(h.proxySrv.URL + "/anything")
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()

	if resp.StatusCode != http.StatusMethodNotAllowed {
		t.Fatalf("plain request = %d, want 405", resp.StatusCode)
	}
}

func TestHostHeaderMustMatchConnectTarget(t *testing.T) {
	h := newHarness(t, nil)

	conn, br, status := h.rawConnect("github.com:443")
	if status != http.StatusOK {
		t.Fatalf("CONNECT = %d", status)
	}

	pool := x509.NewCertPool()
	pool.AddCert(h.proxy.ca.cert)

	tc := tls.Client(conn, &tls.Config{ServerName: "github.com", RootCAs: pool})
	if err := tc.Handshake(); err != nil {
		t.Fatal(err)
	}
	_ = br

	fmt.Fprintf(tc, "GET /user HTTP/1.1\r\nHost: api.github.com\r\n"+
		"Authorization: token %s\r\n\r\n", h.proxy.Placeholder())

	resp, err := http.ReadResponse(bufio.NewReader(tc), nil)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()

	if resp.StatusCode != http.StatusMisdirectedRequest {
		t.Fatalf("mismatched Host = %d, want 421", resp.StatusCode)
	}

	if n := len(h.upstreamRequests()); n != 0 {
		t.Fatalf("upstream saw %d requests for a mismatched Host", n)
	}
}

func TestServerNameMustMatchConnectTarget(t *testing.T) {
	h := newHarness(t, nil)

	conn, _, status := h.rawConnect("github.com:443")
	if status != http.StatusOK {
		t.Fatalf("CONNECT = %d", status)
	}

	pool := x509.NewCertPool()
	pool.AddCert(h.proxy.ca.cert)

	tc := tls.Client(conn, &tls.Config{ServerName: "api.github.com", RootCAs: pool})
	if err := tc.Handshake(); err == nil {
		t.Fatal("proxy minted a certificate for a name other than the CONNECT target")
	}
}

func TestLogsNeverCarryTheTokenOrPlaceholderOrHeaders(t *testing.T) {
	h := newHarness(t, nil)
	c := h.client()
	ph := h.proxy.Placeholder()

	h.do(c, http.MethodGet, "https://api.github.com/user", "Bearer "+ph, "")
	h.do(c, http.MethodPost, "https://github.com/o/r/git-upload-pack?secret=1", basic("x-access-token", ph), "x")
	h.do(h.clientTrusting(h.upCA.cert), http.MethodGet, "https://example.com/", "Bearer "+ph, "")

	logs := h.logs.String()
	for _, banned := range []string{realToken, ph, "Authorization", "Bearer", "secret=1", base64.StdEncoding.EncodeToString([]byte("x-access-token:" + ph))} {
		if strings.Contains(logs, banned) {
			t.Fatalf("log contains %q:\n%s", banned, logs)
		}
	}

	for _, want := range []string{
		"event=request", "host=api.github.com", "method=GET", "path=/user", "status=200", "injected=true",
		"path=/o/r/git-upload-pack",
	} {
		if !strings.Contains(logs, want) {
			t.Fatalf("log lacks %q:\n%s", want, logs)
		}
	}
}

func TestUnreachableUpstreamIsAnErrorNotAToken(t *testing.T) {
	h := newHarness(t, func(c *Config) {
		c.Dial = func(context.Context, string, string) (net.Conn, error) {
			return nil, fmt.Errorf("dial failed for %s", realToken)
		}
	})

	if _, _, got := h.rawConnect("example.com:443"); got != http.StatusBadGateway {
		t.Fatalf("tunnel to an unreachable host = %d, want 502", got)
	}

	if strings.Contains(h.logs.String(), realToken) {
		t.Fatalf("an error carrying the token reached the log:\n%s", h.logs.String())
	}
}

// The default dialer's control runs on the address a name resolved to. The
// test calls it directly because it has no resolver to lie.
func TestDefaultDialerRefusesHostLocalAddresses(t *testing.T) {
	for _, addr := range []string{"127.0.0.1:443", "[::1]:443", "169.254.169.254:443",
		"0.0.0.0:443", "[fe80::1]:443"} {
		if err := refuseLocal("tcp", addr, nil); err == nil {
			t.Fatalf("%s was admitted", addr)
		}
	}

	if err := refuseLocal("tcp", "140.82.112.3:443", nil); err != nil {
		t.Fatalf("a public address was refused: %v", err)
	}
}

func TestPlaceholderIsRandomAndWellFormed(t *testing.T) {
	a := newHarness(t, nil).proxy.Placeholder()
	b := newHarness(t, nil).proxy.Placeholder()

	if !regexp.MustCompile(`^loomvm_[0-9a-f]{32}$`).MatchString(a) {
		t.Fatalf("placeholder %q is malformed", a)
	}

	if a == b {
		t.Fatal("two proxies share a placeholder")
	}
}

func TestNewRejectsBadConfig(t *testing.T) {
	cases := map[string]Config{
		"empty token":      {Inject: DefaultInjectHosts},
		"token with space": {Token: "a b", Inject: DefaultInjectHosts},
		"token newline":    {Token: "abc\n", Inject: DefaultInjectHosts},
		"no injection":     {Token: "abc"},
		"bad allow":        {Token: "abc", Inject: DefaultInjectHosts, Allow: []string{"*.com"}},
		"url in deny":      {Token: "abc", Inject: DefaultInjectHosts, Deny: []string{"https://x.example"}},
	}

	for name, cfg := range cases {
		t.Run(name, func(t *testing.T) {
			if _, err := New(cfg); err == nil {
				t.Fatal("New accepted the config")
			}
		})
	}
}

func TestCAIsConstrainedToTheInjectionHosts(t *testing.T) {
	h := newHarness(t, nil)

	pool := x509.NewCertPool()
	pool.AddCert(h.proxy.ca.cert)

	verify := func(host string) error {
		leaf, err := h.proxy.ca.leaf(host)
		if err != nil {
			return err
		}

		cert, err := x509.ParseCertificate(leaf.Certificate[0])
		if err != nil {
			return err
		}

		_, err = cert.Verify(x509.VerifyOptions{DNSName: host, Roots: pool})

		return err
	}

	for _, host := range DefaultInjectHosts {
		if err := verify(host); err != nil {
			t.Fatalf("%s: %v", host, err)
		}
	}

	if err := verify("example.com"); err == nil {
		t.Fatal("the CA vouches for a host outside the injection set")
	}
}

func TestCAIsECDSAP256AndExpires(t *testing.T) {
	h := newHarness(t, func(c *Config) { c.Lifetime = 2 * time.Hour })

	cert := h.proxy.ca.cert
	if cert.PublicKeyAlgorithm != x509.ECDSA || !cert.IsCA {
		t.Fatalf("CA is %v, IsCA=%v", cert.PublicKeyAlgorithm, cert.IsCA)
	}

	if d := time.Until(cert.NotAfter); d > 2*time.Hour || d < time.Hour {
		t.Fatalf("CA expires in %v, want about 2h", d)
	}
}

func TestGuestFilesHoldNoToken(t *testing.T) {
	h := newHarness(t, nil)
	files := h.proxy.GuestFiles(3128)
	ph := h.proxy.Placeholder()

	targets := map[string]string{}
	for _, f := range files {
		targets[f.Target] = string(f.Content)

		if strings.Contains(string(f.Content), realToken) {
			t.Fatalf("%s contains the real token", f.Target)
		}
	}

	env := targets[EnvPath]
	for _, want := range []string{
		"HTTPS_PROXY=http://192.168.127.1:3128\n", "https_proxy=http://192.168.127.1:3128\n",
		"NO_PROXY=192.168.127.1,", "GH_TOKEN=" + ph + "\n", "GITHUB_TOKEN=" + ph + "\n",
	} {
		if !strings.Contains(env, want) {
			t.Fatalf("env file lacks %q:\n%s", want, env)
		}
	}

	cfg := targets[GitConfigPath]
	for _, want := range []string{
		"proxy = http://192.168.127.1:3128", `[credential "https://github.com"]`,
		"echo username=x-access-token", "${GH_TOKEN:-" + ph + "}",
	} {
		if !strings.Contains(cfg, want) {
			t.Fatalf("gitconfig lacks %q:\n%s", want, cfg)
		}
	}

	if !bytes.Equal([]byte(targets[CAPath]), h.proxy.CACertPEM()) {
		t.Fatal("staged CA differs from the proxy's")
	}
}

// TestGitConfigSendsSSHRemotesThroughHTTPS checks the rewrite with git
// itself: a remote written in either SSH form for an injection host resolves
// to the HTTPS URL the proxy can carry, and a host that gets no credential is
// left as written.
func TestGitConfigSendsSSHRemotesThroughHTTPS(t *testing.T) {
	if _, err := exec.LookPath("git"); err != nil {
		t.Skip("git is not installed")
	}

	h := newHarness(t, nil)

	var cfg []byte
	for _, f := range h.proxy.GuestFiles(3128) {
		if f.Target == GitConfigPath {
			cfg = f.Content
		}
	}

	path := filepath.Join(t.TempDir(), "gitconfig")
	if err := os.WriteFile(path, cfg, 0o600); err != nil {
		t.Fatal(err)
	}

	for remote, want := range map[string]string{
		"git@github.com:owner/repo.git":       "https://github.com/owner/repo.git",
		"ssh://git@github.com/owner/repo.git": "https://github.com/owner/repo.git",
		"https://github.com/owner/repo.git":   "https://github.com/owner/repo.git",
		"git@gitlab.com:owner/repo.git":       "git@gitlab.com:owner/repo.git",
	} {
		cmd := exec.Command("git", "ls-remote", "--get-url", remote)
		cmd.Dir = t.TempDir()
		cmd.Env = append(os.Environ(),
			"GIT_CONFIG_GLOBAL="+path, "GIT_CONFIG_SYSTEM="+os.DevNull,
			"GIT_CONFIG_NOSYSTEM=1")

		out, err := cmd.CombinedOutput()
		if err != nil {
			t.Fatalf("git ls-remote --get-url %s: %v: %s", remote, err, out)
		}

		if got := strings.TrimSpace(string(out)); got != want {
			t.Fatalf("%s resolves to %s, want %s", remote, got, want)
		}
	}
}

func TestCloseEndsOpenTunnels(t *testing.T) {
	h := newHarness(t, nil)

	conn, _, status := h.rawConnect("example.com:443")
	if status != http.StatusOK {
		t.Fatalf("CONNECT = %d", status)
	}

	h.proxy.Close()

	_ = conn.SetReadDeadline(time.Now().Add(5 * time.Second))
	if _, err := conn.Read(make([]byte, 1)); err == nil {
		t.Fatal("read succeeded on a closed tunnel")
	}
}
