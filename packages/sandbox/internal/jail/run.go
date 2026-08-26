package jail

import (
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/roasbeef/loom/sandbox/internal/cgroup"
	"github.com/roasbeef/loom/sandbox/internal/policy"
)

// Request describes one execution.
type Request struct {
	Argv   []string
	Env    map[string]string
	Cwd    string
	Policy policy.Policy
	// ID distinguishes per-exec resources (cgroup names).
	ID uint64
}

// OutputSink receives chunks of child output as they arrive. total is
// the cumulative admitted byte count for the stream including this
// chunk; truncated marks the single chunk on which the cap was hit
// (data may be non-empty and partial on that chunk). Called from pump
// goroutines; implementations must be safe for concurrent use across
// the two streams.
type OutputSink func(stream string, data []byte, total uint64, truncated bool)

// Result is the outcome of one execution.
type Result struct {
	Code            int
	Signal          int
	StdoutBytes     uint64
	StderrBytes     uint64
	StdoutTruncated bool
	StderrTruncated bool
	Enforcement     []string
	Degraded        bool
	WallMs          uint64
	TimedOut        bool
	// Cancelled reports that the helper stopped this execution rather
	// than the execution ending of its own accord — an explicit cancel,
	// or the wall-clock deadline, which climbs the same ladder (TimedOut
	// separates the two causes).
	//
	// It exists because the exit status cannot carry it. A cancelled run
	// whose payload had backgrounded its work reported `code=0 signal=0`
	// — a clean success for an execution that was forcibly truncated —
	// and `code=143` is no better in the other direction: `sh -c 'exit
	// 143'` produces it with no cancel involved. Only the helper knows,
	// and now it says so (#53).
	Cancelled bool
	// PidsMaxEvents is the number of forks the cgroup pids controller
	// denied (0 when no cgroup was attached). Diagnostic; not on the wire.
	PidsMaxEvents uint64
}

// Exec is a running jailed execution.
type Exec struct {
	cmd     *exec.Cmd
	pgid    int
	started time.Time

	stdinW  *os.File
	reportR *os.File

	stdout *StreamLimiter
	stderr *StreamLimiter

	mu       sync.Mutex
	esc      *Escalation
	killT    *time.Timer
	wallT    *time.Timer
	timedOut bool
	stdinEOF bool

	pumps  sync.WaitGroup
	feat   Features
	cgDir  string
	cg     cgroupOutcome
	mounts MountReport
}

// cgroupOutcome records what became of the per-exec cgroup for one
// execution: whether the policy asked for a ceiling only cgroups can
// hold, whether one was actually attached, and — when it was wanted and
// missing — why. All three are needed to report honestly, because
// "no cgroup" means nothing without "and one was asked for".
type cgroupOutcome struct {
	// ceilings names which of memory.max and pids.max the policy asked
	// for. Which, not whether: a skip that names a ceiling the policy
	// never wanted is a false statement about what was dropped.
	ceilings CgroupCeilings
	attached bool
	reason   string
}

func (c cgroupOutcome) wanted() bool { return c.ceilings.any() }

// CgroupCeilings names which of the two ceilings only cgroups can hold
// a policy asked for.
type CgroupCeilings struct {
	Mem  bool
	Pids bool
}

func (c CgroupCeilings) any() bool { return c.Mem || c.Pids }

// names renders the ceilings for a report entry, in the order
// FileWrites applies them.
func (c CgroupCeilings) names() string {
	switch {
	case c.Mem && c.Pids:
		return "memory.max and pids.max"
	case c.Mem:
		return "memory.max"
	case c.Pids:
		return "pids.max"
	}
	return "no cgroup ceiling"
}

// CgroupSkipPrefix opens every cgroup skip entry, so a reader (and the
// self-test, and CI) can recognise the layer without matching a reason
// that varies by machine.
const CgroupSkipPrefix = "cgroup-v2"

// CgroupSkip is the enforcement-report entry the helper emits when a
// policy asked for a memory or process ceiling and no cgroup was
// attached to hold it. Surfaced to the broker as "skip:" + this string,
// which fails a full-enforcement demand — the alternative, saying
// nothing, lets a policy that demanded both ceilings pass strict
// enforcement with neither in place.
func CgroupSkip(reason string, ceilings CgroupCeilings) string {
	if reason == "" {
		reason = "no per-exec cgroup was attached"
	}
	return CgroupSkipPrefix + ": " + reason + "; " + ceilings.names() +
		" NOT applied"
}

// Start launches req under the strongest jail the environment offers.
//
// Process shape (bwrap mode):
//
//	helper ──spawn(setsid)──> bwrap ──> loom-exec --exec (stage 2) ──execve──> target
//
// Degraded mode drops the bwrap link. The policy travels to stage 2 as
// msgpack on fd 3 (the same contract the spec gives the helper itself);
// stage 2 sends its enforcement report back on fd 4 and then execs, so
// the seccomp/Landlock/rlimit state it built persists into the target.
// The whole subtree lives in one fresh session/pgroup owned by the
// direct child; cancellation and cleanup signal the group, never a
// single pid — an orphaned grandchild is still ours to kill.
func Start(req Request, feat Features, selfExe string, sink OutputSink) (*Exec, error) {
	if len(req.Argv) == 0 {
		return nil, fmt.Errorf("jail: empty argv")
	}

	polBytes, err := policy.Encode(req.Policy)
	if err != nil {
		return nil, err
	}

	// fd 3: policy for stage 2. Written fully before the child starts;
	// SandboxPolicyV1 is far below pipe capacity, so this cannot block.
	policyR, policyW, err := os.Pipe()
	if err != nil {
		return nil, fmt.Errorf("jail: policy pipe: %w", err)
	}
	if _, err := policyW.Write(polBytes); err != nil {
		policyR.Close()
		policyW.Close()
		return nil, fmt.Errorf("jail: write policy: %w", err)
	}
	policyW.Close()

	// fd 4: enforcement report from stage 2.
	reportR, reportW, err := os.Pipe()
	if err != nil {
		policyR.Close()
		return nil, fmt.Errorf("jail: report pipe: %w", err)
	}

	stage2 := []string{selfExe, "--exec", "--cwd", req.Cwd, "--"}
	stage2 = append(stage2, req.Argv...)

	var argv []string
	var mounts MountReport
	if feat.BwrapPath != "" {
		// The mount plan is built from a policy whose protected paths
		// have been resolved through their symlinks; see resolveProtected.
		jailed := req.Policy
		jailed.Protected = resolveProtected(req.Policy.Protected)
		kinds := statKinds(jailed.Protected)
		plan := MountPlan(jailed, kinds)

		// A PathMissing protected path bwrap cannot actually mask —
		// creating its mount point needs write access to the parent
		// directory, and the plan leaves that parent read-only — refuses
		// the whole jail with a bare `Can't mkdir parents for PATH:
		// Read-only file system` and exit 1, no different from the
		// payload's own command failing. `~/.ssh`, a default protected
		// path, hits this on any policy that does not also grant write
		// under $HOME: the ordinary case, not an edge one (#60). Loom
		// refuses in its own words, naming the path, before bwrap ever
		// runs; see UnmountableProtected and the "which path lists
		// tolerate a missing path" comment in bwrap.go.
		if bad := UnmountableProtected(kinds, plan); len(bad) > 0 {
			policyR.Close()
			reportR.Close()
			reportW.Close()
			return nil, fmt.Errorf("jail: protected path(s) %s do not "+
				"exist and the region covering their parent directory is "+
				"not writable, so bwrap cannot create the mask for them; "+
				"grant write under the parent directory or remove the "+
				"entry from protected", strings.Join(bad, ", "))
		}

		// Audited here, reported only if stage 2 later proves the plan
		// was actually executed. See mounts.go for both halves.
		mounts = AuditMounts(jailed, plan)
		argv = append([]string{feat.BwrapPath}, BwrapArgs(jailed, kinds)...)
		argv = append(argv, stage2...)
	} else {
		argv = stage2
	}

	cmd := exec.Command(argv[0], argv[1:]...)
	cmd.Env = FilterEnv(req.Env, req.Policy.EnvAllow)
	// New session ⇒ new process group with pgid = child pid, and no
	// controlling terminal. Everything the jail spawns stays in this
	// group unless it setsids itself — and bwrap's PID namespace covers
	// even that escape in non-degraded mode.
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	cmd.ExtraFiles = []*os.File{policyR, reportW} // fds 3 and 4

	stdinR, stdinW, err := os.Pipe()
	if err != nil {
		policyR.Close()
		reportR.Close()
		reportW.Close()
		return nil, fmt.Errorf("jail: stdin pipe: %w", err)
	}
	stdoutR, stdoutW, err := os.Pipe()
	if err != nil {
		policyR.Close()
		reportR.Close()
		reportW.Close()
		stdinR.Close()
		stdinW.Close()
		return nil, fmt.Errorf("jail: stdout pipe: %w", err)
	}
	stderrR, stderrW, err := os.Pipe()
	if err != nil {
		policyR.Close()
		reportR.Close()
		reportW.Close()
		stdinR.Close()
		stdinW.Close()
		stdoutR.Close()
		stdoutW.Close()
		return nil, fmt.Errorf("jail: stderr pipe: %w", err)
	}
	cmd.Stdin = stdinR
	cmd.Stdout = stdoutW
	cmd.Stderr = stderrW

	if err := cmd.Start(); err != nil {
		for _, f := range []*os.File{policyR, reportR, reportW, stdinR, stdinW, stdoutR, stdoutW, stderrR, stderrW} {
			f.Close()
		}
		return nil, fmt.Errorf("jail: start: %w", err)
	}
	// Close the parent's copies of the child-held ends so pipe EOFs
	// track the child subtree's lifetime, not ours.
	policyR.Close()
	reportW.Close()
	stdinR.Close()
	stdoutW.Close()
	stderrW.Close()

	e := &Exec{
		cmd:     cmd,
		pgid:    cmd.Process.Pid, // Setsid ⇒ pgid == child pid
		started: time.Now(),
		stdinW:  stdinW,
		reportR: reportR,
		stdout:  NewStreamLimiter(req.Policy.Limits.OutputBytes),
		stderr:  NewStreamLimiter(req.Policy.Limits.OutputBytes),
		esc:     NewEscalation(KillGrace),
		feat:    feat,
		mounts:  mounts,
	}

	// Best-effort cgroup membership: the group is configured before the
	// child is moved in, and descendants inherit membership, so the
	// mem/pids ceilings bind the whole subtree. The child could in
	// principle fork in the gap before Enter; phase 1 accepts that race
	// (the broker learns from Enforcement whether cgroups applied at
	// all, which is the decision that matters).
	e.cg.ceilings = CgroupCeilings{
		Mem:  req.Policy.Limits.MemBytes > 0,
		Pids: req.Policy.Limits.Pids > 0,
	}
	if e.cg.wanted() {
		e.cg.reason = feat.CgroupReason
	}
	if feat.CgroupDir != "" && e.cg.wanted() {
		name := "exec-" + strconv.FormatUint(req.ID, 10) + "-" + strconv.Itoa(cmd.Process.Pid)
		dir, err := cgroup.Setup(feat.CgroupDir, name, cgroup.LimitsView{
			MemBytes: req.Policy.Limits.MemBytes,
			Pids:     req.Policy.Limits.Pids,
		})
		switch {
		case err != nil:
			e.cg.reason = err.Error()
		default:
			if err := cgroup.Enter(dir, cmd.Process.Pid); err == nil {
				e.cgDir = dir
				e.cg.attached = true
			} else {
				e.cg.reason = err.Error()
				_ = cgroup.Cleanup(dir)
			}
		}
	}

	e.pumps.Add(2)
	go e.pump("stdout", stdoutR, e.stdout, sink)
	go e.pump("stderr", stderrR, e.stderr, sink)

	if wall := req.Policy.Limits.WallSeconds; wall > 0 {
		e.wallT = time.AfterFunc(time.Duration(wall)*time.Second, func() {
			e.mu.Lock()
			e.timedOut = true
			e.mu.Unlock()
			e.Cancel()
		})
	}

	return e, nil
}

// pump moves one output stream from the child to the sink, enforcing
// the truncation cap. After the cap it keeps reading and discards so
// the child never blocks on a full pipe.
func (e *Exec) pump(name string, r *os.File, lim *StreamLimiter, sink OutputSink) {
	defer e.pumps.Done()
	defer r.Close()
	buf := make([]byte, 32*1024)
	for {
		n, err := r.Read(buf)
		if n > 0 {
			allow, justTruncated := lim.Admit(n)
			if allow > 0 || justTruncated {
				chunk := make([]byte, allow)
				copy(chunk, buf[:allow])
				sink(name, chunk, lim.Admitted(), justTruncated)
			}
		}
		if err != nil {
			return // EOF or read error: stream is over either way
		}
	}
}

// WriteStdin forwards a stdin chunk; eof closes the child's stdin after
// the write. Writes after eof are rejected.
func (e *Exec) WriteStdin(data []byte, eof bool) error {
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.stdinEOF {
		return fmt.Errorf("jail: stdin already closed")
	}
	if len(data) > 0 {
		if _, err := e.stdinW.Write(data); err != nil {
			return fmt.Errorf("jail: write stdin: %w", err)
		}
	}
	if eof {
		e.stdinEOF = true
		if err := e.stdinW.Close(); err != nil {
			return fmt.Errorf("jail: close stdin: %w", err)
		}
	}
	return nil
}

// Cancel starts (or re-requests, idempotently) TERM→KILL escalation of
// the child's process group.
//
// The two rungs are addressed differently, and cancel.go is the whole
// argument for why: TERM goes to the payload and spares the jail's
// scaffolding, because killing the bwrap supervisor tears the PID
// namespace down and turns the grace into an instant SIGKILL for
// everything inside it. KILL goes to the group, because at that point
// demolishing the cage is the point.
func (e *Exec) Cancel() {
	e.mu.Lock()
	defer e.mu.Unlock()
	now := time.Now()
	if e.esc.Cancel(now) == SigTerm {
		e.term()
		deadline, _ := e.esc.KillDeadline()
		e.killT = time.AfterFunc(deadline.Sub(now), func() {
			e.mu.Lock()
			defer e.mu.Unlock()
			if e.esc.Tick(time.Now()) == SigKill {
				_ = syscall.Kill(-e.pgid, syscall.SIGKILL)
			}
		})
	}
}

// term delivers the TERM rung. In degraded mode the group leader is the
// payload itself and the whole group is the right addressee; under bwrap
// the leader is the supervisor, which must be spared, and the payload is
// found by descent rather than by process group — a group is something
// a payload can leave with one syscall, and descent is not (see
// cancel.go). A selection that comes back empty — no procfs, a race
// before the payload appeared — falls back to the group, because a TERM
// that was silently not sent is worse than one sent too widely: the
// caller would wait out a grace nobody was asked to use.
func (e *Exec) term() {
	if e.feat.BwrapPath != "" {
		if targets := TermTargets(scanProcesses(), e.pgid); len(targets) > 0 {
			for _, pid := range targets {
				_ = syscall.Kill(pid, syscall.SIGTERM)
			}
			return
		}
	}
	_ = syscall.Kill(-e.pgid, syscall.SIGTERM)
}

// Wait blocks until the direct child exits, then sweeps the process
// group and drains the output pumps. Order matters: waitpid first, then
// a SIGKILL sweep of the pgroup (reaping orphaned grandchildren that
// hold the output pipes open), and only then joining the pumps — which
// is what lets Wait return promptly even when a `sleep 30 &` orphan
// survives its parent.
func (e *Exec) Wait() Result {
	err := e.cmd.Wait()

	// The direct child is gone; anything left in the group is an orphan
	// (and in bwrap mode the dying PID namespace has already taken the
	// whole subtree with it). ESRCH is the happy case.
	_ = syscall.Kill(-e.pgid, syscall.SIGKILL)

	e.pumps.Wait()

	e.mu.Lock()
	if e.wallT != nil {
		e.wallT.Stop()
	}
	if e.killT != nil {
		e.killT.Stop()
	}
	e.esc.Exited()
	cancelled := e.esc.Cancelled()
	timedOut := e.timedOut
	e.mu.Unlock()

	e.stdinW.Close()

	s2 := readStage2Report(e.reportR)
	e.reportR.Close()

	var pidsMax uint64
	if e.cgDir != "" {
		pidsMax = cgroup.ReadPidsEventsMax(e.cgDir)
		_ = cgroup.Cleanup(e.cgDir)
	}

	res := Result{
		PidsMaxEvents:   pidsMax,
		StdoutBytes:     e.stdout.Admitted(),
		StderrBytes:     e.stderr.Admitted(),
		StdoutTruncated: e.stdout.Truncated(),
		StderrTruncated: e.stderr.Truncated(),
		Degraded:        e.feat.Degraded(),
		WallMs:          uint64(time.Since(e.started) / time.Millisecond),
		TimedOut:        timedOut,
		Cancelled:       cancelled,
	}

	res.Enforcement = enforcementEntries(e.feat, e.cg, e.mounts, s2)

	if err == nil {
		res.Code = 0
	} else if exitErr, ok := err.(*exec.ExitError); ok {
		ws, ok := exitErr.Sys().(syscall.WaitStatus)
		if ok && ws.Signaled() {
			res.Signal = int(ws.Signal())
			res.Code = 128 + res.Signal
		} else {
			res.Code = exitErr.ExitCode()
		}
	} else {
		// Wait itself failed; report as a synthetic failure code.
		res.Code = 127
	}
	return res
}

// stage2Report is what came back on fd 4, and whether anything did.
//
// The distinction is the whole point. A stage 2 that dies before writing
// its report — a bwrap that could not exec it, a missing helper binary,
// a namespace setup that failed — produced an *empty* report, which the
// old code folded into "no skips" and a full-enforcement demand
// therefore accepted. Silence about a layer is not evidence the layer
// was applied, so it is recorded as its own condition and reported as a
// skip.
type stage2Report struct {
	rep Report
	// received is true only when stage 2 actually said something. It is
	// also the helper's only witness that bubblewrap built a namespace
	// and exec'd into it: the report can arrive from nowhere else.
	received bool
	// err carries a report that arrived but could not be read.
	err string
}

// readStage2Report drains fd 4 and classifies what it found.
func readStage2Report(r io.Reader) stage2Report {
	rep, err := ReadReport(r)
	switch {
	case err != nil:
		return stage2Report{err: err.Error()}
	case len(rep.Applied) == 0 && len(rep.Skipped) == 0:
		return stage2Report{}
	default:
		return stage2Report{rep: rep, received: true}
	}
}

// Stage2SkipPrefix opens the skip entry emitted when stage 2 said
// nothing, so a reader can recognise the condition without matching a
// reason that varies by cause.
const Stage2SkipPrefix = "stage2"

// Stage2Skip is the enforcement entry for a stage 2 that never reported.
// Everything the inner stage applies — rlimits, Landlock, no_new_privs,
// the seccomp network filter — is unknown when it is silent, and so is
// whether bubblewrap ever built the jail around it.
func Stage2Skip(reason string) string {
	if reason == "" {
		reason = "no enforcement report arrived on fd 4 before the " +
			"execution ended"
	}
	return Stage2SkipPrefix + ": " + reason +
		"; the in-process layers (rlimits, Landlock, no_new_privs, " +
		"seccomp) cannot be confirmed to have been applied"
}

// BwrapUnwitnessedSkip is the entry emitted when bubblewrap was on the
// path and asked to build a jail, but nothing witnessed it doing so.
const BwrapUnwitnessedSkip = "bwrap: stage 2 sent no enforcement report " +
	"on fd 4, so neither the namespaces nor the mount plan can be " +
	"confirmed to have been built"

// enforcementEntries assembles the per-exec enforcement summary the
// exec_exit frame carries: what the supervising helper applied around the
// execution, then what stage 2 applied inside it, then everything either
// of them skipped, each prefixed `skip:`.
//
// An unsupported platform is stated first and as a skip, because it is the
// entry that governs how to read every other one: on a build with no jail
// the rlimit and pgroup entries are true and are also the whole of the
// confinement, and a reader who missed that would take the list for a
// sandbox report.
//
// Every layer reports on the same terms: applied, or skipped with a
// reason — and, since #54, **presence is the claim and silence is a
// skip**. Two rules carry that:
//
//   - `bwrap` and the `mounts:` audit are claimed only when stage 2
//     reported, because that report is the one thing that could not have
//     arrived unless bubblewrap built the namespace and exec'd into it.
//     bwrap merely being on PATH proved nothing, and `[bwrap]` on its own
//     used to satisfy a full-enforcement demand.
//   - a stage 2 that said nothing yields `skip:stage2: …` rather than an
//     absent inner report, so the layers it owns are refused rather than
//     assumed.
//
// The cgroup layer is the one the helper itself owns, and it reports the
// same way. A policy that asked for `mem_bytes` or `pids` and got no
// cgroup has an unenforced ceiling, and saying nothing about it would let
// exactly that result satisfy a full-enforcement demand.
func enforcementEntries(feat Features, cg cgroupOutcome, mounts MountReport, s2 stage2Report) []string {
	var out []string
	if !feat.Platform.Implemented {
		out = append(out, "skip:"+feat.Platform.Reason)
	}
	if feat.BwrapPath != "" {
		if s2.received {
			out = append(out, "bwrap")
			if mounts.Applied != "" {
				out = append(out, mounts.Applied)
			}
		} else {
			out = append(out, "skip:"+BwrapUnwitnessedSkip)
		}
	}
	if cg.attached {
		out = append(out, "cgroup-v2")
	}
	out = append(out, s2.rep.Applied...)
	if feat.BwrapPath != "" && s2.received {
		for _, m := range mounts.Skipped {
			out = append(out, "skip:"+m)
		}
	}
	if cg.wanted() && !cg.attached {
		out = append(out, "skip:"+CgroupSkip(cg.reason, cg.ceilings))
	}
	for _, s := range s2.rep.Skipped {
		out = append(out, "skip:"+s)
	}
	if !s2.received {
		out = append(out, "skip:"+Stage2Skip(s2.err))
	}
	return out
}

// Pgid exposes the process group id (tests only).
func (e *Exec) Pgid() int { return e.pgid }

// statKinds classifies protected paths for bwrap mask construction.
//
// os.Stat, not os.Lstat: the mask forms differ by inode type and the
// type that matters is the *target's*. A symlink to a directory that
// Lstat called a file would be masked with the file form — a bind of a
// character device over a directory, which the kernel refuses with
// ENOTDIR. That fails closed rather than open (the old file form was
// `--ro-bind dir dir`, which succeeded and left the directory readable),
// but a jail that will not start is still a jail nobody gets. Callers
// pass paths already resolved by resolveProtected, so the stat and the
// mount see the same inode.
func statKinds(paths []string) map[string]PathKind {
	kinds := make(map[string]PathKind, len(paths))
	for _, p := range paths {
		fi, err := os.Stat(filepath.Clean(p))
		switch {
		case err != nil:
			kinds[p] = PathMissing
		case fi.IsDir():
			kinds[p] = PathDir
		default:
			kinds[p] = PathFile
		}
	}
	return kinds
}

// resolveProtected rewrites each protected path through its symlinks, so
// the mask lands on the inode rather than on the name.
//
// bwrap resolves a mount's destination inside the pivot root it is
// building, where a symlink's target may not exist yet. Measured with
// real bubblewrap: `--ro-bind link link` on a symlink to a directory
// fails with "Can't bind mount ...: No such file or directory" and exit
// 1, the `--tmpfs` form fails identically, and for an *absolute* symlink
// every mask form fails. Masking the resolved target works — and it
// covers both names, because the symlink still resolves into the mask
// from inside the jail. A protected `~/.ssh` that is a symlink is not
// exotic, and the failure mode is a jail that will not start.
//
// A path that does not resolve keeps its cleaned original: that is the
// PathMissing case, where masking the name is exactly the point — a
// protected path that does not exist yet must stay uncreatable.
func resolveProtected(paths []string) []string {
	if len(paths) == 0 {
		return nil
	}
	out := make([]string, 0, len(paths))
	for _, p := range paths {
		resolved, err := filepath.EvalSymlinks(p)
		if err != nil {
			resolved = filepath.Clean(p)
		}
		out = append(out, resolved)
	}
	return out
}
