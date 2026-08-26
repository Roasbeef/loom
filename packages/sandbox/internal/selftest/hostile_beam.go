package selftest

import (
	_ "embed"
	"errors"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/roasbeef/loom/sandbox/internal/jail"
	"github.com/roasbeef/loom/sandbox/internal/policy"
)

// The hostile-satellite tabletop's kernel half.
//
// packages/codemode/CLAUDE.md states the security argument this probe
// exists to turn from an argument into an observation:
//
//	The cap token authenticates the channel; it does not confine an
//	escaped `.beam`. The token file is readable inside the jail by
//	necessity. What confines a hostile `.beam` is the kernel jail and
//	the broker's per-call policy check.
//
// The broker's half is proved in-process by packages/codemode's
// satellite tests (an unauthenticated `cap_call` denied, and the genuine
// token presented against a policy-forbidden call and refused). This is
// the other half, and it is the one only a kernel can answer: an
// adversary that never touches the cap channel at all. A hand-written
// Erlang module — no Gleam, no vetting, no compile service, no manifest
// — is dropped into a node's code path inside a real jail and calls the
// runtime's own effect functions directly.
//
// # What "contained" has to mean here
//
// A `.beam` that fails to load, a node that never boots, and a path that
// happens not to exist all produce the same surface symptom as
// containment, and none of them is containment. Three separate things
// keep those apart:
//
//  1. The adversary announces itself (`hostile-loaded`) and announces
//     that it finished (`hostile-done`), so a node that died on boot is
//     not read as a node that was contained.
//  2. It performs two effects the policy *allows* — reading a bound-in
//     file, writing inside the writable root — and reports them. A run
//     of pure denials with no successes would be a broken module, and is
//     reported as a probe failure rather than as enforcement.
//  3. The same `.beam`, on the same host, against the same paths and the
//     same live TCP listener, is run once with no jail at all first. If
//     the escape does not succeed there, the probe skips: containment
//     that cannot be told apart from a host which never permitted the
//     reach in the first place proves nothing, and saying so is cheaper
//     than a green run that means nothing.
//
// That unjailed run is the probe's own non-vacuity control, and it is
// the reason this probe is worth having rather than a comment claiming
// the jail would hold.
//
// # What it does not claim
//
// Not "reaches nothing on the filesystem". The helper's base view
// ro-binds the whole host filesystem and Landlock grants RODirs("/"), so
// an unprotected host path is *readable* from inside the jail today;
// `readable_roots` does not narrow reads, only `protected` removes them.
// That gap is written up in
// protocol-change/004-sandbox-policy-explicit-mounts.md and is not this
// probe's to close. What is claimed, and observed, is that the adversary
// cannot write outside the writable roots, cannot see a protected path,
// and cannot reach the network.

//go:embed loom_hostile.erl
var hostileSource []byte

// hostileModule is the Erlang module name, which erlc requires to match
// the source file's basename.
const hostileModule = "loom_hostile"

// hostileSecret is planted under the protected directory. Its whole job
// is to be quotable in a failure message: if this string comes back out
// of the jail, the mask did not hold.
const hostileSecret = "LOOM_CAP_TOKEN=the-jail-was-supposed-to-hide-this\n"

// hostilePatience bounds the unjailed control run, which has no policy
// wall limit to stop it. Booting a BEAM is most of a normal run; the
// module's own connect attempt times out after 3s inside that. The jailed
// run is bounded by the policy's own wall limit instead.
const hostilePatience = 60 * time.Second

func probeHostileBeam(feat jail.Features, selfExe string) probeResult {
	if feat.BwrapPath == "" {
		return probeResult{outcome: skipped,
			detail: "confining an unvetted .beam needs bwrap's mount and " +
				"network namespaces; degraded mode has neither, and " +
				"Landlock alone cannot hide a protected path"}
	}
	rig, why, err := newHostileRig()
	if err != nil {
		return probeResult{outcome: failed, detail: err.Error()}
	}
	if why != "" {
		return probeResult{outcome: skipped, detail: why}
	}
	defer rig.close()

	// --- the negative control: the same escape, with no jail ----------
	free, err := rig.layout("unjailed")
	if err != nil {
		return probeResult{outcome: failed, detail: err.Error()}
	}
	control := rig.unjailed(free)
	switch {
	case !control.loaded:
		return probeResult{outcome: skipped,
			detail: "the adversary's .beam does not even load outside a jail " +
				"on this host, so nothing was attempted: " + control.summary()}
	case !control.escaped():
		return probeResult{outcome: skipped,
			detail: "the escape does not succeed on this host even unjailed " +
				"(" + control.summary() + "), so a denial inside the jail " +
				"would not be evidence of containment"}
	}

	// --- the same adversary, in the jail ------------------------------
	caged, err := rig.layout("jailed")
	if err != nil {
		return probeResult{outcome: failed, detail: err.Error()}
	}
	got, out, err := rig.jailed(feat, selfExe, caged, true)
	if err != nil {
		return probeResult{outcome: failed, detail: "spawn: " + err.Error()}
	}

	switch {
	case !got.loaded:
		return probeResult{outcome: failed,
			detail: "the node never booted inside the jail, so nothing was " +
				"contained — this is a broken probe, not enforcement " +
				"(out " + quote(out) + ")"}
	case !got.readOK || !got.writeOK:
		return probeResult{outcome: failed,
			detail: "the adversary could not perform the effects the policy " +
				"ALLOWS, so its denials are not evidence of a jail: " +
				got.summary()}
	case got.secretRead:
		return probeResult{outcome: failed,
			detail: "a protected path was readable from inside the jail: the " +
				"planted secret came back out"}
	case got.outsideWrite:
		return probeResult{outcome: failed,
			detail: "the .beam wrote outside every writable root"}
	case got.netConnect:
		return probeResult{outcome: failed,
			detail: "the .beam reached a host TCP listener under network off"}
	case !got.done:
		return probeResult{outcome: failed,
			detail: "the adversary did not run to completion, so its later " +
				"attempts may never have been made: " + got.summary()}
	}

	// Ground truth on the host, independent of anything the jailed
	// process chose to print.
	if _, err := os.Stat(caged.victim); err == nil {
		return probeResult{outcome: failed,
			detail: "the victim file exists on the host despite the jail " +
				"reporting the write denied"}
	}
	planted, err := os.ReadFile(caged.secret)
	if err != nil || string(planted) != hostileSecret {
		return probeResult{outcome: failed,
			detail: "the protected secret was altered on the host"}
	}
	return probeResult{outcome: enforced}
}

// hostilePaths is one run's filesystem layout: what the adversary is
// allowed to touch, and the two places it should not reach.
type hostilePaths struct {
	// inside is the writable root.
	inside string
	// readable is a file under inside, bound in and readable.
	readable string
	// writable is where the adversary's permitted write goes.
	writable string
	// vault is a protected directory; secret is the file planted in it.
	vault, secret string
	// victim is outside every writable root.
	victim string
}

// hostileLayout builds one run's directories under root/name. The two
// runs get separate layouts so the unjailed control's successful escape
// cannot be mistaken for the jailed run's.
func hostileLayout(root, name string) (hostilePaths, error) {
	base := filepath.Join(root, name)
	p := hostilePaths{
		inside:   filepath.Join(base, "inside"),
		readable: filepath.Join(base, "inside", "bound-in.txt"),
		writable: filepath.Join(base, "inside", "beam-wrote.txt"),
		vault:    filepath.Join(base, "inside", "vault"),
		secret:   filepath.Join(base, "inside", "vault", "cap-token"),
		victim:   filepath.Join(base, "outside", "victim"),
	}
	for _, d := range []string{p.inside, p.vault, filepath.Dir(p.victim)} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			return p, err
		}
	}
	if err := os.WriteFile(p.readable, []byte("a file the policy binds in\n"), 0o644); err != nil {
		return p, err
	}
	if err := os.WriteFile(p.secret, []byte(hostileSecret), 0o600); err != nil {
		return p, err
	}
	return p, nil
}

// hostileArgv is the command line that loads the adversary into a node
// and runs it. `-run` hands the plain arguments to the module as a list
// of strings; `-noshell` keeps the BEAM from wanting a terminal.
func hostileArgv(erl, ebin string, p hostilePaths, port int) []string {
	return []string{
		erl, "-noshell", "-pa", ebin,
		"-run", hostileModule, "run",
		p.readable, p.writable, p.secret, p.victim, strconv.Itoa(port),
	}
}

// buildHostileBeam compiles the embedded module on the host and returns
// the directory holding the resulting .beam.
func buildHostileBeam(erlc, dir string) (string, error) {
	src := filepath.Join(dir, hostileModule+".erl")
	if err := os.WriteFile(src, hostileSource, 0o644); err != nil {
		return "", err
	}
	ebin := filepath.Join(dir, "ebin")
	if err := os.MkdirAll(ebin, 0o755); err != nil {
		return "", err
	}
	cmd := exec.Command(erlc, "-o", ebin, src)
	if out, err := cmd.CombinedOutput(); err != nil {
		return "", fmt.Errorf("erlc: %w: %s", err, strings.TrimSpace(string(out)))
	}
	return ebin, nil
}

// hostileRig is one run of the probe's apparatus: a scratch directory, the
// adversary compiled into it, and a live loopback listener held open for
// the adversary to reach for.
type hostileRig struct {
	dir, ebin, erl string
	ln             net.Listener
	port           int
}

// newHostileRig builds the .beam on the host and opens the control
// listener. A non-empty reason means the apparatus cannot be assembled
// here at all — which is a skip, never a pass; a non-nil error means it
// could have been and was not, which is a probe failure.
func newHostileRig() (*hostileRig, string, error) {
	erlc, errc := exec.LookPath("erlc")
	erl, erre := exec.LookPath("erl")
	if errc != nil || erre != nil {
		return nil, "no Erlang toolchain on this host (erl/erlc), so the " +
			"adversary's .beam can be neither built nor loaded: nothing " +
			"was attempted, and nothing was contained", nil
	}
	dir, err := probeDir()
	if err != nil {
		return nil, "", err
	}
	// Built on the host, outside every jail: a real adversary arrives as
	// object code, and compiling it in there would only be testing erlc.
	ebin, err := buildHostileBeam(erlc, dir)
	if err != nil {
		os.RemoveAll(dir)
		return nil, "", fmt.Errorf("building the hostile .beam: %w", err)
	}
	// Loopback, not the internet: reaching it is an unambiguous positive
	// with no DNS, no egress, and no dependence on the runner having a
	// route out.
	// A host that will not let the probe hold a loopback listener is a
	// host where the network half was never attempted, so it is a skip
	// rather than a failure: there would be nothing for the jail to deny
	// the adversary a route to.
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		os.RemoveAll(dir)
		return nil, "no loopback listener on this host (" + err.Error() +
			"), so the adversary has nothing to reach for and the network " +
			"half was never attempted", nil
	}
	addr, ok := ln.Addr().(*net.TCPAddr)
	if !ok {
		ln.Close()
		os.RemoveAll(dir)
		return nil, "", errors.New("control listener is not TCP")
	}
	go acceptForever(ln)
	return &hostileRig{dir: dir, ebin: ebin, erl: erl, ln: ln, port: addr.Port}, "", nil
}

func (r *hostileRig) close() {
	r.ln.Close()
	os.RemoveAll(r.dir)
}

// layout gives one run its own directories, so the escape a permissive
// run demonstrates can never be mistaken for a confined run's.
func (r *hostileRig) layout(name string) (hostilePaths, error) {
	return hostileLayout(r.dir, name)
}

// unjailed is the probe's non-vacuity control: the identical module, the
// identical paths, and no confinement whatsoever. Everything it touches
// belongs to the rig — a scratch directory it created and a loopback
// listener it is holding open — so the escape it demonstrates reaches
// nothing that outlives the probe.
func (r *hostileRig) unjailed(p hostilePaths) hostileReport {
	argv := hostileArgv(r.erl, r.ebin, p, r.port)
	cmd := exec.Command(argv[0], argv[1:]...)
	// Somewhere writable, so a BEAM crash dump lands inside the scratch
	// directory the rig removes.
	cmd.Dir = p.inside
	cmd.Env = envList(defaultEnv)
	done := make(chan struct{})
	var out []byte
	var err error
	go func() {
		out, err = cmd.CombinedOutput()
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(hostilePatience):
		if cmd.Process != nil {
			_ = cmd.Process.Kill()
		}
		<-done
	}
	if err != nil && len(out) == 0 {
		return parseHostile("unjailed run failed to start: " + err.Error())
	}
	return parseHostile(string(out))
}

// jailed runs the same argv through the real jail path. `confined` picks
// the policy: the one under test, or the same policy with exactly the
// three mechanisms this probe measures granted instead of withheld.
func (r *hostileRig) jailed(
	feat jail.Features, selfExe string, p hostilePaths, confined bool,
) (hostileReport, string, error) {
	var out strings.Builder
	sink := func(stream string, data []byte, total uint64, trunc bool) {
		out.Write(data)
	}
	ex, err := jail.Start(jail.Request{
		Argv:   hostileArgv(r.erl, r.ebin, p, r.port),
		Env:    defaultEnv,
		Cwd:    "/",
		Policy: hostilePolicy(p, confined),
	}, feat, selfExe, sink)
	if err != nil {
		return hostileReport{}, "", err
	}
	if err := ex.WriteStdin(nil, true); err != nil {
		return hostileReport{}, "", err
	}
	ex.Wait()
	return parseHostile(out.String()), out.String(), nil
}

// hostilePolicy is the pair of policies the probe's claim rests on.
//
// Confined is the real one: network off, the run's `inside` directory the
// only writable root, and the vault declared protected. Permissive is the
// same policy with those three mechanisms — and only those three —
// granted: the run's whole base directory writable so the victim path
// falls inside a writable root, no protected entry over the vault, and
// network full. Nothing else moves, which is what makes the difference
// between the two runs attributable to the mechanisms rather than to the
// jail's presence.
//
// Even permissive stays inside the rig's scratch directory. "Writable
// root" here is a temp directory the probe made and deletes; the
// adversary is being handed its own sandbox back, not the host.
func hostilePolicy(p hostilePaths, confined bool) policy.Policy {
	if !confined {
		pol := basePolicy(filepath.Dir(p.inside))
		pol.Network = policy.Network{Mode: policy.NetworkFull}
		return pol
	}
	pol := basePolicy(p.inside)
	pol.Protected = []string{p.vault}
	return pol
}

// hostileReport is one run of the adversary, as it described itself.
type hostileReport struct {
	loaded, done bool
	// The effects the policy allows, and which must succeed for the
	// denials below to mean anything.
	readOK, writeOK bool
	// The three escapes: true means the adversary got through.
	secretRead, outsideWrite, netConnect bool
	// Why each escape was refused, as the runtime reported it.
	secretWhy, outsideWhy, netWhy string
}

// escaped reports whether all three reaches succeeded, which is what the
// unjailed control must show for the jailed run to mean anything.
func (r hostileReport) escaped() bool {
	return r.secretRead && r.outsideWrite && r.netConnect
}

// summary renders the report for a probe detail line: which of the six
// things happened, in the adversary's own words.
func (r hostileReport) summary() string {
	parts := []string{
		"loaded=" + yesno(r.loaded),
		"read=" + yesno(r.readOK),
		"write=" + yesno(r.writeOK),
		"secret=" + reach(r.secretRead, r.secretWhy),
		"outside=" + reach(r.outsideWrite, r.outsideWhy),
		"net=" + reach(r.netConnect, r.netWhy),
		"done=" + yesno(r.done),
	}
	return strings.Join(parts, " ")
}

func yesno(b bool) string {
	if b {
		return "yes"
	}
	return "no"
}

// reach renders one escape attempt: "reached", or the refusal the
// runtime gave, or "never attempted" when the line is missing entirely
// — a distinction the whole probe turns on.
func reach(got bool, why string) string {
	switch {
	case got:
		return "REACHED"
	case why == "":
		return "never-attempted"
	default:
		return "denied(" + why + ")"
	}
}

// parseHostile reads the adversary's verdict lines. Every line is an
// explicit statement; nothing is inferred from silence.
func parseHostile(out string) hostileReport {
	var r hostileReport
	for _, line := range strings.Split(out, "\n") {
		line = strings.TrimSpace(line)
		switch {
		case line == "hostile-loaded":
			r.loaded = true
		case line == "hostile-done":
			r.done = true
		case line == "control-read-ok":
			r.readOK = true
		case line == "control-write-ok":
			r.writeOK = true
		case strings.HasPrefix(line, "secret-read-SUCCEEDED"):
			r.secretRead = true
		case strings.HasPrefix(line, "secret-read-denied:"):
			r.secretWhy = strings.TrimPrefix(line, "secret-read-denied:")
		case line == "outside-write-SUCCEEDED":
			r.outsideWrite = true
		case strings.HasPrefix(line, "outside-write-denied:"):
			r.outsideWhy = strings.TrimPrefix(line, "outside-write-denied:")
		case line == "net-CONNECTED":
			r.netConnect = true
		case strings.HasPrefix(line, "net-denied:"):
			r.netWhy = strings.TrimPrefix(line, "net-denied:")
		}
	}
	return r
}

// acceptForever drains the control listener until it is closed. The
// connection itself is uninteresting: reaching it at all is the finding.
func acceptForever(ln net.Listener) {
	for {
		c, err := ln.Accept()
		if err != nil {
			return
		}
		_ = c.Close()
	}
}

// listenerPort extracts the bound TCP port.
func listenerPort(ln net.Listener) (int, bool) {
	addr, ok := ln.Addr().(*net.TCPAddr)
	if !ok {
		return 0, false
	}
	return addr.Port, true
}

// envList turns the probe environment map into the KEY=VALUE form
// os/exec wants. The jail path takes the map directly; the unjailed
// control has to build the list itself, and building it from the same
// map is what keeps the two runs comparable.
func envList(env map[string]string) []string {
	out := make([]string, 0, len(env))
	for k, v := range env {
		out = append(out, k+"="+v)
	}
	return out
}

// quote renders captured output for a failure message without letting a
// flood of it swamp the report.
func quote(s string) string {
	const max = 400
	if len(s) > max {
		s = s[:max] + "..."
	}
	return fmt.Sprintf("%q", s)
}

// HostileBeamRun is one jailed run of the adversary, for the package's
// external test.
type HostileBeamRun struct {
	// Loaded and Done say whether the module ran and finished; every
	// verdict below is meaningless without them.
	Loaded, Done bool
	// ReadOK and WriteOK are the effects the policy allows.
	ReadOK, WriteOK bool
	// The three reaches: true means the adversary got through.
	SecretRead, OutsideWrite, NetConnect bool
	// Summary is the whole report in one line, for a failure message.
	Summary string
}

// RunHostileBeamForTest runs the hostile `.beam` once through the real
// jail path — `confined` picking the policy under test or the same
// policy with its three mechanisms granted — and reports what it reached.
//
// This exists for the non-vacuity test, and that is the whole point of
// it. `probeHostileBeam` reports ENFORCED when three attempts fail, and
// three attempts failing is exactly what a broken probe also looks like.
// The permissive run is how the tree keeps a record that the same
// adversary, the same argv, and the same jail *do* reach all three when
// the policy stops asking the kernel to stop them.
//
// A non-empty reason means the apparatus could not be assembled here
// (no Erlang, no bwrap), which is a skip and never a pass.
func RunHostileBeamForTest(selfExe string, confined bool) (HostileBeamRun, string, error) {
	feat := jail.DetectFeatures()
	if feat.BwrapPath == "" {
		return HostileBeamRun{}, "no bwrap: there is no jail to grant or withhold", nil
	}
	rig, why, err := newHostileRig()
	if err != nil {
		return HostileBeamRun{}, "", err
	}
	if why != "" {
		return HostileBeamRun{}, why, nil
	}
	defer rig.close()

	name := "granted"
	if confined {
		name = "withheld"
	}
	p, err := rig.layout(name)
	if err != nil {
		return HostileBeamRun{}, "", err
	}
	got, _, err := rig.jailed(feat, selfExe, p, confined)
	if err != nil {
		return HostileBeamRun{}, "", err
	}
	return HostileBeamRun{
		Loaded:       got.loaded,
		Done:         got.done,
		ReadOK:       got.readOK,
		WriteOK:      got.writeOK,
		SecretRead:   got.secretRead,
		OutsideWrite: got.outsideWrite,
		NetConnect:   got.netConnect,
		Summary:      got.summary(),
	}, "", nil
}
