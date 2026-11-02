// Package ghproxy is the credential-injecting HTTPS proxy of the microVM tier.
//
// An agent inside a guest needs to push branches and open pull requests with
// git and gh, which means GitHub must see a token. The developer's real token
// must never enter the guest, because the guest runs model-influenced code and
// anything it can read it can send anywhere its egress allows. The proxy runs
// in the launcher on the host, as the guest's only path to GitHub: the guest
// holds a placeholder, and the proxy replaces it with the real token in flight.
//
// # What the proxy accepts
//
// It is a CONNECT-only forward proxy. A CONNECT target must be a hostname on
// port 443 that the allowlist admits and the deny list does not. What happens
// next depends on the injection list, which is separate from the allowlist and
// explicit:
//
//   - A host on the injection list is intercepted. The proxy terminates TLS with
//     a leaf certificate minted by the per-VM CA, reads HTTP/1.1 requests,
//     replaces the placeholder in the Authorization header, and forwards each
//     request to the real host over TLS with the system roots.
//   - Any other admitted host is tunnelled byte for byte, so the guest sees the
//     host's own certificate and the proxy sees only the destination.
//   - Everything else is refused at CONNECT with a 403.
//
// Injection never widens egress: an injection host the allowlist does not admit
// is refused like any other.
//
// # What the token can reach
//
// The token is substituted only into an Authorization header whose whole
// credential, or whole Basic user or password, is the placeholder. It is never
// put in a URL, a body or another header, and never written to a log: the logs
// record the destination, method, path without its query, status, byte counts
// and whether a substitution happened, and nothing else about the request.
//
// # Where it listens
//
// The proxy is an http.Handler. The launcher registers it as a hosted service
// on go-microvm's virtual gateway, 192.168.127.1, which exists only inside the
// launcher's network stack, so no host socket carries it and no one but the
// guest can connect.
package ghproxy

import (
	"bufio"
	"context"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"strings"
	"sync"
	"syscall"
	"time"
)

// ConnectPort is the only port a CONNECT may name. Both GitHub's API and its
// git transport are HTTPS on 443, and a fixed port keeps the proxy from being
// used to reach arbitrary services on an allowlisted name.
const ConnectPort = "443"

// DefaultInjectHosts are the hosts git and gh send GitHub credentials to.
var DefaultInjectHosts = []string{"github.com", "api.github.com", "uploads.github.com"}

// DefaultLifetime bounds the CA when Config.Lifetime is zero.
const DefaultLifetime = 24 * time.Hour

// Config is everything a proxy decides about a guest's HTTPS traffic.
type Config struct {
	// Token is the real credential. It is held in memory, substituted for
	// the placeholder, and never logged or written.
	Token string

	// Allow is the set of hosts a CONNECT may name, as globs: exact names
	// and names with a leading "*.". Empty admits nothing.
	Allow []string

	// Deny is a set of hosts refused even when Allow admits them.
	Deny []string

	// Inject is the set of hosts whose traffic is intercepted so the token
	// can be injected. It is separate from Allow and must be named
	// explicitly; Allow decides whether a host may be reached at all.
	Inject []string

	// Lifetime is how long the CA is valid. Zero selects DefaultLifetime.
	// The launcher passes its own timeout plus a margin, so the certificate
	// authority does not outlive the VM it was made for.
	Lifetime time.Duration

	// Logger receives one line per CONNECT and per injected request. Nil
	// discards them.
	Logger *slog.Logger

	// Dial opens connections to upstream hosts. Nil selects a dialer that
	// refuses loopback, link-local, unspecified and multicast addresses, so
	// an allowlisted name that resolves to the host itself is still not a
	// way to reach it.
	Dial func(ctx context.Context, network, addr string) (net.Conn, error)

	// UpstreamRoots verifies the real hosts' certificates. Nil selects the
	// system roots.
	UpstreamRoots *x509.CertPool
}

// Proxy serves CONNECT requests for one guest. Create it with New and give it
// to the guest's network as an http.Handler; Close ends its connections.
type Proxy struct {
	allow, deny, inject hostSet
	inj                 injector
	ca                  *ca
	log                 *slog.Logger
	dial                func(ctx context.Context, network, addr string) (net.Conn, error)
	transport           *http.Transport

	ctx    context.Context
	cancel context.CancelFunc

	mu    sync.Mutex
	conns map[net.Conn]struct{}
}

// New builds a proxy and generates its CA. It fails on a token that could not
// be placed in a header, a malformed host glob, or an empty injection set.
//
// ## Examples
//
//	p, err := ghproxy.New(ghproxy.Config{
//		Token:  token,
//		Allow:  []string{"github.com", "api.github.com"},
//		Inject: ghproxy.DefaultInjectHosts,
//	})
func New(cfg Config) (*Proxy, error) {
	if err := checkToken(cfg.Token); err != nil {
		return nil, err
	}

	allow, err := newHostSet(cfg.Allow)
	if err != nil {
		return nil, err
	}

	deny, err := newHostSet(cfg.Deny)
	if err != nil {
		return nil, err
	}

	inject, err := newHostSet(cfg.Inject)
	if err != nil {
		return nil, err
	}

	if len(cfg.Inject) == 0 {
		return nil, errors.New("ghproxy: no injection hosts")
	}

	lifetime := cfg.Lifetime
	if lifetime == 0 {
		lifetime = DefaultLifetime
	}

	authority, err := newCA(lifetime, inject.domains())
	if err != nil {
		return nil, err
	}

	placeholder, err := newPlaceholder()
	if err != nil {
		return nil, err
	}

	log := cfg.Logger
	if log == nil {
		log = slog.New(slog.NewTextHandler(io.Discard, nil))
	}

	dial := cfg.Dial
	if dial == nil {
		dial = (&net.Dialer{Timeout: 15 * time.Second, Control: refuseLocal}).DialContext
	}

	ctx, cancel := context.WithCancel(context.Background())

	return &Proxy{
		allow:  allow,
		deny:   deny,
		inject: inject,
		inj:    injector{placeholder: placeholder, token: cfg.Token},
		ca:     authority,
		log:    log,
		dial:   dial,
		transport: &http.Transport{
			// No Proxy: the upstream leg must not honour the launcher's
			// own proxy environment, which could point back here.
			DialContext:         dial,
			TLSClientConfig:     &tls.Config{RootCAs: cfg.UpstreamRoots, MinVersion: tls.VersionTLS12},
			TLSHandshakeTimeout: 15 * time.Second,
			IdleConnTimeout:     90 * time.Second,
			MaxIdleConnsPerHost: 4,

			// The client chose its own Accept-Encoding; the proxy passes
			// the body through as the upstream sent it.
			DisableCompression: true,
		},
		ctx:    ctx,
		cancel: cancel,
		conns:  make(map[net.Conn]struct{}),
	}, nil
}

// checkToken refuses a token that cannot be a bare header credential. A space
// or control character would let a malformed token change the header's
// structure, and `gh auth token` output with a trailing newline is the likely
// way one arrives.
func checkToken(token string) error {
	if token == "" {
		return errors.New("ghproxy: empty token")
	}

	for _, r := range token {
		if r <= ' ' || r >= 0x7f {
			return errors.New("ghproxy: token has a space or control character")
		}
	}

	return nil
}

// newPlaceholder returns "loomvm_" and 32 hex characters. It is random per
// proxy, so a placeholder copied out of one guest is worth nothing against
// another proxy, and nothing at all against GitHub.
func newPlaceholder() (string, error) {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		return "", fmt.Errorf("ghproxy: placeholder: %w", err)
	}

	return "loomvm_" + hex.EncodeToString(b[:]), nil
}

// Placeholder is the value the guest is given in place of the token.
func (p *Proxy) Placeholder() string { return p.inj.placeholder }

// CACertPEM is the CA certificate the guest must trust. The private key has no
// accessor.
func (p *Proxy) CACertPEM() []byte { return p.ca.pem }

// InjectHosts lists the hosts the proxy intercepts, as the DNS domains the CA
// is constrained to.
func (p *Proxy) InjectHosts() []string { return p.inject.domains() }

// Close ends every open connection and the idle upstream connections. It does
// not unbind the handler; the network stack it was registered with does that.
func (p *Proxy) Close() {
	p.cancel()

	p.mu.Lock()
	for c := range p.conns {
		_ = c.Close()
	}
	p.mu.Unlock()

	p.transport.CloseIdleConnections()
}

// ServeHTTP accepts CONNECT and refuses every other method. The handler is
// registered as a go-microvm hosted service, which is an http.Server, so a
// CONNECT arrives as an ordinary request whose connection the handler takes
// over.
func (p *Proxy) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodConnect {
		w.Header().Set("Allow", http.MethodConnect)
		http.Error(w, "this proxy accepts CONNECT only", http.StatusMethodNotAllowed)
		p.log.Info("refused", "event", "connect", "method", r.Method, "reason", "not CONNECT")

		return
	}

	host, reason := p.admit(r.Host)
	if reason != "" {
		http.Error(w, "refused: "+reason, http.StatusForbidden)
		p.log.Info("refused", "event", "connect", "host", r.Host, "reason", reason)

		return
	}

	if p.inject.matches(host) {
		p.intercept(w, host)
	} else {
		p.tunnel(w, host)
	}
}

// admit parses a CONNECT authority and says why it is refused, or returns the
// normalised host and an empty reason.
func (p *Proxy) admit(authority string) (host, reason string) {
	h, port, err := net.SplitHostPort(authority)
	if err != nil {
		return "", "malformed CONNECT target"
	}

	host = normalizeHost(h)

	switch {
	case port != ConnectPort:
		return "", "port is not " + ConnectPort

	case host == "" || net.ParseIP(host) != nil:
		return "", "target is not a hostname"

	case p.deny.matches(host):
		return "", "host is on the deny list"

	case !p.allow.matches(host):
		return "", "host is not on the allowlist"
	}

	return host, ""
}

// tunnel connects to host and copies bytes both ways without looking at them.
// The upstream connection is made before the 200, so an unreachable host is a
// 502 the client can report instead of a tunnel that opens and then dies.
func (p *Proxy) tunnel(w http.ResponseWriter, host string) {
	upstream, err := p.dial(p.ctx, "tcp", net.JoinHostPort(host, ConnectPort))
	if err != nil {
		http.Error(w, "upstream unreachable", http.StatusBadGateway)
		p.log.Info("failed", "event", "connect", "host", host, "mode", "tunnel",
			"reason", p.scrub(err.Error()))

		return
	}
	defer upstream.Close()

	client, ok := p.accept(w)
	if !ok {
		return
	}
	defer p.release(client)

	p.log.Info("opened", "event", "connect", "host", host, "mode", "tunnel")

	started := time.Now()
	up, down := pipe(client, upstream)

	p.log.Info("closed", "event", "connect", "host", host, "mode", "tunnel",
		"bytes_up", up, "bytes_down", down, "duration", time.Since(started).Round(time.Millisecond))
}

// intercept takes over the guest's connection, answers the TLS handshake with
// a leaf minted for host, and serves the HTTP requests inside it until the
// connection closes.
func (p *Proxy) intercept(w http.ResponseWriter, host string) {
	client, ok := p.accept(w)
	if !ok {
		return
	}
	defer p.release(client)

	p.log.Info("opened", "event", "connect", "host", host, "mode", "intercept")

	tlsConn := tls.Server(client, &tls.Config{
		MinVersion: tls.VersionTLS12,
		NextProtos: []string{"http/1.1"},

		// The certificate is minted for the name the guest asked for, and
		// that name must be the CONNECT target. A client that connects to
		// one host and asks for another's certificate gets neither.
		GetCertificate: func(hello *tls.ClientHelloInfo) (*tls.Certificate, error) {
			if normalizeHost(hello.ServerName) != host {
				return nil, fmt.Errorf("server name %q does not match CONNECT target",
					hello.ServerName)
			}

			return p.ca.leaf(host)
		},
	})

	_ = tlsConn.SetDeadline(time.Now().Add(15 * time.Second))
	if err := tlsConn.HandshakeContext(p.ctx); err != nil {
		p.log.Info("failed", "event", "connect", "host", host, "mode", "intercept",
			"reason", "tls handshake: "+p.scrub(err.Error()))

		return
	}
	_ = tlsConn.SetDeadline(time.Time{})

	srv := &http.Server{
		Handler:           p.injectingHandler(host),
		ReadHeaderTimeout: 30 * time.Second,
		IdleTimeout:       2 * time.Minute,
		ErrorLog:          slog.NewLogLogger(slog.NewTextHandler(io.Discard, nil), slog.LevelError),
	}

	// Serve returns when the single connection closes.
	_ = srv.Serve(newSingleConnListener(tlsConn))
}

// accept answers the CONNECT with a 200 and returns the hijacked connection,
// registered so Close can end it. Deadlines the hosted service's server set
// for ordinary requests are cleared, because a tunnel outlives them.
func (p *Proxy) accept(w http.ResponseWriter) (net.Conn, bool) {
	hj, ok := w.(http.Hijacker)
	if !ok {
		http.Error(w, "connection cannot be taken over", http.StatusInternalServerError)
		return nil, false
	}

	conn, brw, err := hj.Hijack()
	if err != nil {
		return nil, false
	}

	_ = conn.SetDeadline(time.Time{})

	if _, err := io.WriteString(conn, "HTTP/1.1 200 Connection Established\r\n\r\n"); err != nil {
		_ = conn.Close()
		return nil, false
	}

	p.mu.Lock()
	p.conns[conn] = struct{}{}
	p.mu.Unlock()

	// A client that sent its first bytes before reading the 200 left them in
	// the server's buffer; the connection handed back reads them first.
	return &bufferedConn{Conn: conn, r: brw.Reader}, true
}

// release forgets and closes a connection taken by accept.
func (p *Proxy) release(c net.Conn) {
	p.mu.Lock()
	delete(p.conns, c.(*bufferedConn).Conn)
	p.mu.Unlock()

	_ = c.Close()
}

// bufferedConn is a hijacked connection that reads the server's buffered bytes
// before the socket.
type bufferedConn struct {
	net.Conn
	r *bufio.Reader
}

func (c *bufferedConn) Read(b []byte) (int, error) { return c.r.Read(b) }

// CloseWrite half-closes the connection when the underlying one can.
func (c *bufferedConn) CloseWrite() error {
	if cw, ok := c.Conn.(interface{ CloseWrite() error }); ok {
		return cw.CloseWrite()
	}

	return nil
}

// pipe copies both directions until each side has finished and returns the
// bytes moved from a to b and from b to a. A direction that ends half-closes
// its destination, so the peer sees the end of the stream and can finish its
// own.
func pipe(a, b net.Conn) (aToB, bToA int64) {
	var wg sync.WaitGroup

	copyHalf := func(dst, src net.Conn, n *int64) {
		defer wg.Done()

		*n, _ = io.Copy(dst, src)

		if cw, ok := dst.(interface{ CloseWrite() error }); ok {
			_ = cw.CloseWrite()
		} else {
			_ = dst.Close()
		}
	}

	wg.Add(2)
	go copyHalf(b, a, &aToB)
	go copyHalf(a, b, &bToA)
	wg.Wait()

	return aToB, bToA
}

// record carries what the handler learns about one request to the code that
// logs it.
type record struct {
	injected bool
}

type recordKey struct{}

// injectingHandler serves the requests inside one intercepted connection.
func (p *Proxy) injectingHandler(host string) http.Handler {
	target := &url.URL{Scheme: "https", Host: net.JoinHostPort(host, ConnectPort)}

	rp := &httputil.ReverseProxy{
		Transport: p.transport,

		// -1 writes each chunk to the client as it arrives, which git's
		// streaming responses need.
		FlushInterval: -1,

		Rewrite: func(pr *httputil.ProxyRequest) {
			pr.Out.URL.Scheme = target.Scheme
			pr.Out.URL.Host = target.Host
			pr.Out.Host = host

			if p.inj.apply(pr.Out.Header) {
				pr.In.Context().Value(recordKey{}).(*record).injected = true
			}
		},

		ErrorHandler: func(w http.ResponseWriter, _ *http.Request, err error) {
			w.WriteHeader(http.StatusBadGateway)
			p.log.Info("failed", "event", "request", "host", host,
				"reason", p.scrub(err.Error()))
		},
	}

	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		// Without this check a guest could connect to a host with
		// an injection entry and send requests addressed to another.
		if normalizeHost(hostOnly(r.Host)) != host {
			http.Error(w, "Host header does not match the CONNECT target",
				http.StatusMisdirectedRequest)
			p.log.Info("refused", "event", "request", "host", host,
				"method", r.Method, "reason", "Host header mismatch")

			return
		}

		rec := &record{}
		sw := &countingWriter{ResponseWriter: w, status: http.StatusOK}

		rp.ServeHTTP(sw, r.WithContext(context.WithValue(r.Context(), recordKey{}, rec)))

		p.log.Info("served", "event", "request", "host", host, "method", r.Method,
			"path", r.URL.Path, "status", sw.status, "bytes", sw.bytes,
			"injected", rec.injected)
	})
}

// hostOnly drops a port from a Host header value.
func hostOnly(h string) string {
	if host, _, err := net.SplitHostPort(h); err == nil {
		return host
	}

	return h
}

// countingWriter records the status and body size of a response for the log.
type countingWriter struct {
	http.ResponseWriter
	status      int
	bytes       int64
	wroteHeader bool
}

func (c *countingWriter) WriteHeader(code int) {
	if !c.wroteHeader && code >= 200 {
		c.status, c.wroteHeader = code, true
	}

	c.ResponseWriter.WriteHeader(code)
}

func (c *countingWriter) Write(b []byte) (int, error) {
	n, err := c.ResponseWriter.Write(b)
	c.bytes += int64(n)

	return n, err
}

// Unwrap lets http.ResponseController reach the real writer, which
// ReverseProxy uses to flush.
func (c *countingWriter) Unwrap() http.ResponseWriter { return c.ResponseWriter }

// scrub removes the token and the placeholder from text bound for a log. No
// error here is expected to contain either, so this is a backstop and not the
// mechanism: the mechanism is that the logs are given no header values.
func (p *Proxy) scrub(s string) string {
	s = strings.ReplaceAll(s, p.inj.token, "[redacted]")

	return strings.ReplaceAll(s, p.inj.placeholder, "[redacted]")
}

// refuseLocal is a net.Dialer Control that rejects an address the proxy must
// not reach on the guest's behalf. It runs after name resolution, so it judges
// the address a name resolved to, which is the one that would be connected.
func refuseLocal(_, address string, _ syscall.RawConn) error {
	host, _, err := net.SplitHostPort(address)
	if err != nil {
		return err
	}

	ip := net.ParseIP(host)
	if ip == nil || ip.IsLoopback() || ip.IsLinkLocalUnicast() || ip.IsLinkLocalMulticast() ||
		ip.IsUnspecified() || ip.IsMulticast() {

		return fmt.Errorf("ghproxy: refusing to connect to %s", host)
	}

	return nil
}

// singleConnListener lets an http.Server serve exactly one connection that was
// accepted elsewhere. Accept returns the connection once, then blocks until it
// is closed and fails, which ends Serve.
type singleConnListener struct {
	conns chan net.Conn
	done  chan struct{}
	addr  net.Addr
	once  sync.Once
}

func newSingleConnListener(c net.Conn) net.Listener {
	l := &singleConnListener{
		conns: make(chan net.Conn, 1),
		done:  make(chan struct{}),
		addr:  c.LocalAddr(),
	}
	l.conns <- &closeNotifier{Conn: c, closed: l.close}

	return l
}

func (l *singleConnListener) Accept() (net.Conn, error) {
	select {
	case c := <-l.conns:
		return c, nil

	case <-l.done:
		return nil, net.ErrClosed
	}
}

func (l *singleConnListener) Close() error {
	l.close()
	return nil
}

func (l *singleConnListener) Addr() net.Addr { return l.addr }

func (l *singleConnListener) close() { l.once.Do(func() { close(l.done) }) }

// closeNotifier tells the listener when the server closes the connection.
type closeNotifier struct {
	net.Conn
	closed func()
}

func (c *closeNotifier) Close() error {
	c.closed()
	return c.Conn.Close()
}
