package jail

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
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

	pumps sync.WaitGroup
	feat  Features
	cgDir string
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
	if feat.BwrapPath != "" {
		kinds := statKinds(req.Policy.Protected)
		argv = append([]string{feat.BwrapPath}, BwrapArgs(req.Policy, kinds)...)
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
	}

	// Best-effort cgroup membership: the group is configured before the
	// child is moved in, and descendants inherit membership, so the
	// mem/pids ceilings bind the whole subtree. The child could in
	// principle fork in the gap before Enter; phase 1 accepts that race
	// (the broker learns from Enforcement whether cgroups applied at
	// all, which is the decision that matters).
	if feat.CgroupDir != "" && (req.Policy.Limits.MemBytes > 0 || req.Policy.Limits.Pids > 0) {
		name := "exec-" + strconv.FormatUint(req.ID, 10) + "-" + strconv.Itoa(cmd.Process.Pid)
		dir, err := cgroup.Setup(feat.CgroupDir, name, cgroup.LimitsView{
			MemBytes: req.Policy.Limits.MemBytes,
			Pids:     req.Policy.Limits.Pids,
		})
		if err == nil {
			if err := cgroup.Enter(dir, cmd.Process.Pid); err == nil {
				e.cgDir = dir
			} else {
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
func (e *Exec) Cancel() {
	e.mu.Lock()
	defer e.mu.Unlock()
	now := time.Now()
	if e.esc.Cancel(now) == SigTerm {
		_ = syscall.Kill(-e.pgid, syscall.SIGTERM)
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
	timedOut := e.timedOut
	e.mu.Unlock()

	e.stdinW.Close()

	rep, _ := ReadReport(e.reportR)
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
	}

	if e.feat.BwrapPath != "" {
		res.Enforcement = append(res.Enforcement, "bwrap")
	}
	if e.cgDir != "" {
		res.Enforcement = append(res.Enforcement, "cgroup-v2")
	}
	res.Enforcement = append(res.Enforcement, rep.Applied...)
	for _, s := range rep.Skipped {
		res.Enforcement = append(res.Enforcement, "skip:"+s)
	}

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

// Pgid exposes the process group id (tests only).
func (e *Exec) Pgid() int { return e.pgid }

// statKinds classifies protected paths for bwrap mask construction.
func statKinds(paths []string) map[string]PathKind {
	kinds := make(map[string]PathKind, len(paths))
	for _, p := range paths {
		fi, err := os.Lstat(filepath.Clean(p))
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
