//go:build linux

package jail_test

import (
	"net"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/roasbeef/loom/sandbox/internal/jail"
	"github.com/roasbeef/loom/sandbox/internal/policy"
	"github.com/roasbeef/loom/sandbox/internal/testbin"
)

// loopbackPolicy is testPolicy with the loopback network mode.
func loopbackPolicy(t *testing.T) policy.Policy {
	pol := testPolicy(t)
	pol.Network = policy.Network{Mode: policy.NetworkLoopback}
	return pol
}

// needLoopbackJail skips where the mode cannot run at all: loopback
// needs the bwrap namespace and the seccomp filter, and Start refuses it
// otherwise (see TestStartRefusesLoopbackWithoutAFreshNetworkNamespace).
func needLoopbackJail(t *testing.T) {
	t.Helper()
	feat := jail.DetectFeatures()
	if feat.BwrapPath == "" {
		t.Skip("loopback mode needs bwrap's fresh network namespace")
	}
	if !feat.Seccomp {
		t.Skip("kernel lacks seccomp filter support")
	}
}

// probeLines runs `loom-exec --probe-loopback ARGS...` in a jail under
// pol to completion and returns its name=result lines as a map.
func probeLines(t *testing.T, pol policy.Policy, args ...string) map[string]string {
	t.Helper()
	c := newCollector()
	argv := append([]string{testbin.Helper(t), "--probe-loopback"}, args...)
	ex := start(t, pol, argv, c.sink)
	_ = ex.WriteStdin(nil, true)
	res := ex.Wait()
	out := parseProbe(c.out())
	if len(out) == 0 {
		t.Fatalf("probe produced no results (exit %d): %q", res.Code, c.out())
	}
	return out
}

func parseProbe(s string) map[string]string {
	out := map[string]string{}
	for _, line := range strings.Split(s, "\n") {
		if k, v, ok := strings.Cut(strings.TrimSpace(line), "="); ok {
			out[k] = v
		}
	}
	return out
}

func expect(t *testing.T, got map[string]string, want map[string]string) {
	t.Helper()
	for k, v := range want {
		if got[k] != v {
			t.Errorf("%s = %q, want %q (all: %v)", k, got[k], v, got)
		}
	}
}

// Inside a loopback jail a process can listen on 127.0.0.1 and connect
// to itself, the sockets the mode must refuse get EPERM, TCP_ULP is
// refused while an ordinary TCP option is not, and a connection to a
// non-loopback address fails.
func TestLoopbackJailAllowsOnlyIPv4TCPOnLo(t *testing.T) {
	needLoopbackJail(t)
	got := probeLines(t, loopbackPolicy(t), "battery")
	expect(t, got, map[string]string{
		"listen":       "ok",
		"self-connect": "ok",

		"connect-doc-range": "ENETUNREACH",
		"connect-private":   "ENETUNREACH",

		"socket-inet6-stream":    "EPERM",
		"socket-inet-dgram":      "EPERM",
		"socket-inet-raw":        "EPERM",
		"socket-inet-sctp":       "EPERM",
		"socket-inet-mptcp":      "EPERM",
		"socket-packet":          "EPERM",
		"socket-netlink-route":   "EPERM",
		"socket-netlink-generic": "EPERM",
		"socketpair-inet":        "EPERM",
		"socketpair-unix":        "ok",

		"setsockopt-tcp-nodelay": "ok",
		"setsockopt-tcp-ulp":     "EPERM",
	})
}

// A listener on the host's loopback at some port is not reachable from
// the jail at the same address: the namespace is fresh, not the host's.
func TestLoopbackJailCannotReachTheHostsLoopback(t *testing.T) {
	needLoopbackJail(t)
	ln, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		t.Skipf("no host loopback listener: %v", err)
	}
	defer ln.Close()
	port := strconv.Itoa(ln.Addr().(*net.TCPAddr).Port)

	got := probeLines(t, loopbackPolicy(t), "battery", port)
	expect(t, got, map[string]string{"connect-host-port": "ECONNREFUSED"})
}

// Two jails at once cannot reach each other's listeners, which is the
// property that keeps one job from talking to another.
func TestLoopbackJailsCannotReachEachOther(t *testing.T) {
	needLoopbackJail(t)
	holder := newCollector()
	hold := start(t, loopbackPolicy(t),
		[]string{testbin.Helper(t), "--probe-loopback", "hold"}, holder.sink)
	defer func() {
		_ = hold.WriteStdin(nil, true)
		hold.Wait()
	}()

	var port string
	waitFor(t, 10*time.Second, func() bool {
		port = parseProbe(holder.out())["port"]
		return port != ""
	})

	// The holder's own namespace answers on that port, so a jail that
	// reached it would see a successful connection.
	got := probeLines(t, loopbackPolicy(t), "dial", port)
	expect(t, got, map[string]string{"dial": "ECONNREFUSED"})
}

// The regression for the filter change: an off-mode jail still refuses
// the TCP socket, and everything else the battery tries.
func TestOffJailStillRefusesTCPSockets(t *testing.T) {
	feat := jail.DetectFeatures()
	if !feat.Seccomp {
		t.Skip("kernel lacks seccomp filter support")
	}
	got := probeLines(t, testPolicy(t), "battery")
	expect(t, got, map[string]string{
		"listen":               "EPERM",
		"socket-inet-dgram":    "EPERM",
		"socket-inet6-stream":  "EPERM",
		"socket-netlink-route": "EPERM",
		"socketpair-unix":      "ok",
		"setsockopt-tcp-ulp":   "no-socket:EPERM",
	})
}
