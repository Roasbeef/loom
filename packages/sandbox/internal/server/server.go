// Package server multiplexes a bounded number of independent jailed executions.
// The shared transport and helper death remain a shared failure boundary.
package server

import (
	"errors"
	"fmt"
	"io"
	"os"
	"sync"

	"github.com/roasbeef/loom/sandbox/internal/framing"
	"github.com/roasbeef/loom/sandbox/internal/jail"
	"github.com/roasbeef/loom/sandbox/internal/policy"
)

// Server drives the protocol loop.
type Server struct {
	conn    *framing.Conn
	feat    jail.Features
	selfExe string
	basePol policy.Policy
	nextID  uint64
	mu      sync.Mutex
	running map[uint64]*execution
}

// MaxConcurrency bounds both running jails and terminal cleanup obligations.
const MaxConcurrency = 4

// execution keeps custody until both the terminal write and cleanup finish.
type execution struct {
	exec *jail.Exec
	done chan struct{}
}

// New builds a server. basePol is the fd-3 policy: the default for
// exec_start frames that omit their own.
func New(conn *framing.Conn, feat jail.Features, selfExe string, basePol policy.Policy) *Server {
	return &Server{conn: conn, feat: feat, selfExe: selfExe, basePol: basePol, running: make(map[uint64]*execution)}
}

// Run performs the hello exchange and serves frames until the peer
// requests shutdown, closes the channel, or a protocol violation forces us
// to stop. Every return joins all admitted jails before the helper exits.
// Per spec §3.3.6 a malformed frame closes the channel (after an error
// frame so the broker can settle the effect in-band).
func (s *Server) Run() error {
	// A native exit can witness retirement only after the execution's Wait
	// completes. Keep this obligation on every return, including malformed
	// traffic during an execution, rather than on selected dispatch branches.
	defer s.reapRunning()

	// The helper introduces itself first: the broker learns the honest
	// feature set before it commits any work to us.
	if err := s.conn.Write(s.originID(), framing.KindHello, framing.Hello{
		Proto:          framing.ExecProtocolVersion,
		Peer:           "exec-helper",
		Features:       s.feat.List(),
		MaxConcurrency: MaxConcurrency,
	}); err != nil {
		return err
	}

	helloSeen := false
	for {
		f, err := s.conn.Read()
		if err == io.EOF {
			return nil
		}
		if err != nil {
			// Malformed frame: report in-band, then close.
			_ = s.conn.WriteError(0, framing.ErrCodeMalformed, err.Error())
			return fmt.Errorf("server: malformed frame: %w", err)
		}

		if !helloSeen && f.Kind != framing.KindHello {
			_ = s.conn.WriteError(f.ID, framing.ErrCodeProto, "expected hello before "+f.Kind)
			return fmt.Errorf("server: %s before hello", f.Kind)
		}

		switch f.Kind {
		case framing.KindHello:
			var h framing.Hello
			if err := framing.DecodeBody(f.Body, &h); err != nil {
				_ = s.conn.WriteError(f.ID, framing.ErrCodeMalformed, err.Error())
				return err
			}
			// Name both numbers, not just the peer's. A helper and a
			// broker built from different trees is the failure this
			// check exists for, and "unsupported proto 1" alone leaves
			// the reader to guess what this binary wanted.
			if h.Proto != framing.ExecProtocolVersion {
				_ = s.conn.WriteError(f.ID, framing.ErrCodeProto,
					fmt.Sprintf("peer speaks exec protocol %d; this helper speaks %d",
						h.Proto, framing.ExecProtocolVersion))
				return fmt.Errorf("server: exec protocol mismatch: peer %d, helper %d",
					h.Proto, framing.ExecProtocolVersion)
			}
			helloSeen = true

		case framing.KindHeartbeat:
			_ = s.conn.Write(f.ID, framing.KindHeartbeat, map[string]any{})

		case framing.KindExecStart:
			s.handleExecStart(f)

		case framing.KindExecStdin:
			s.handleExecStdin(f)

		case framing.KindCancel:
			var body framing.Cancel
			if err := framing.DecodeBody(f.Body, &body); err != nil || body.ExecID == 0 {
				_ = s.conn.WriteError(f.ID, framing.ErrCodeMalformed, "cancel: positive exec_id required")
				continue
			}
			s.mu.Lock()
			entry := s.running[uint64(body.ExecID)]
			s.mu.Unlock()
			if entry != nil {
				entry.exec.Cancel()
			}

		case framing.KindShutdown:
			var body map[string]any
			if err := framing.DecodeBody(f.Body, &body); err != nil || body == nil || len(body) != 0 {
				_ = s.conn.WriteError(f.ID, framing.ErrCodeMalformed, "shutdown: expected empty map")
				return fmt.Errorf("server: shutdown requires an empty map")
			}

			// Stop dispatch before cancellation. The deferred join emits the
			// admitted executions' terminal frames, then allows native exit.
			// Stdin stays open so the broker can retain its exit-status witness;
			// neither a reply frame nor port closure is that witness.
			return nil

		default:
			// Unknown kind: unlike a malformed frame this parses fine,
			// so answer in-band and keep the channel; the broker may be
			// newer than us and able to downgrade.
			_ = s.conn.WriteError(f.ID, framing.ErrCodeUnknownKind, f.Kind)
		}
	}
}

func (s *Server) handleExecStart(f framing.Frame) {
	// Capacity includes terminal writes and cleanup, not just live children.
	s.mu.Lock()
	_, duplicate := s.running[f.ID]
	full := len(s.running) >= MaxConcurrency
	s.mu.Unlock()
	if f.ID == 0 || duplicate {
		_ = s.conn.WriteError(f.ID, framing.ErrCodeMalformed, "exec_start: duplicate or zero execution id")
		return
	}
	if full {
		_ = s.conn.WriteError(f.ID, framing.ErrCodeBusy, "execution capacity exhausted")
		return
	}

	var body framing.ExecStart
	if err := framing.DecodeBody(f.Body, &body); err != nil {
		_ = s.conn.WriteError(f.ID, framing.ErrCodeMalformed, err.Error())
		return
	}
	if len(body.Argv) == 0 {
		_ = s.conn.WriteError(f.ID, framing.ErrCodeMalformed, "exec_start: empty argv")
		return
	}
	if len(body.Token) == 0 {
		_ = s.conn.WriteError(f.ID, framing.ErrCodeMalformed, "exec_start: missing token")
		return
	}

	pol := s.basePol
	if len(body.Policy) > 0 {
		p, err := policy.Decode(body.Policy)
		if err != nil {
			_ = s.conn.WriteError(f.ID, framing.ErrCodeBadPolicy, err.Error())
			return
		}
		pol = p
	}

	ex, err := jail.Start(jail.Request{
		Argv:   body.Argv,
		Env:    body.Env,
		Cwd:    body.Cwd,
		Policy: pol,
		ID:     f.ID,
	}, s.feat, s.selfExe, s.outputSink(f.ID))
	if err != nil {
		_ = s.conn.WriteError(f.ID, framing.ErrCodeSpawn, err.Error())
		return
	}

	entry := &execution{exec: ex, done: make(chan struct{})}
	s.mu.Lock()
	s.running[f.ID] = entry
	s.mu.Unlock()

	go func() {
		res, release := ex.Settle()

		// Cleanup runs without the registry lock so it cannot delay sibling
		// cancellation. The terminal frame then releases capacity atomically
		// with its visibility to the peer: a refill after reading exec_exit
		// must not observe this completed execution as a busy slot.
		release()
		s.mu.Lock()
		_ = s.conn.Write(f.ID, framing.KindExecExit, framing.ExecExit{
			Code:            res.Code,
			Signal:          res.Signal,
			StdoutBytes:     res.StdoutBytes,
			StderrBytes:     res.StderrBytes,
			StdoutTruncated: res.StdoutTruncated,
			StderrTruncated: res.StderrTruncated,
			Enforcement:     res.Enforcement,
			Degraded:        res.Degraded,
			WallMs:          res.WallMs,
			TimedOut:        res.TimedOut,
			Cancelled:       res.Cancelled,
		})
		delete(s.running, f.ID)
		close(entry.done)
		s.mu.Unlock()
	}()
}

// handleExecStdin admits bounded input without blocking the shared frame loop.
// Refusal is correlated to this stdin request, not the target execution start.
func (s *Server) handleExecStdin(f framing.Frame) {
	var body framing.ExecStdin
	if err := framing.DecodeBody(f.Body, &body); err != nil || body.ExecID == 0 {
		_ = s.conn.WriteError(f.ID, framing.ErrCodeMalformed, "exec_stdin: positive exec_id required")
		return
	}
	s.mu.Lock()
	entry := s.running[uint64(body.ExecID)]
	s.mu.Unlock()
	if entry == nil {
		_ = s.conn.WriteError(f.ID, framing.ErrCodeNoExec, "no execution running for exec_id")
		return
	}
	if err := entry.exec.WriteStdin(body.Data, body.EOF); err != nil {
		_ = s.conn.WriteError(f.ID, framing.ErrCodeNoExec, err.Error())
		if errors.Is(err, jail.ErrStdinPendingLimit) {
			entry.exec.Cancel()
		}
	}
}

// outputSink forwards child output as exec_out frames correlated to the
// exec_start id.
func (s *Server) outputSink(id uint64) jail.OutputSink {
	return func(stream string, data []byte, total uint64, truncated bool) {
		_ = s.conn.Write(id, framing.KindExecOut, framing.ExecOut{
			Stream:    stream,
			Data:      data,
			Bytes:     total,
			Truncated: truncated,
		})
	}
}

// reapRunning cancels every admitted jail before joining all terminal writes
// and native cleanup. No admission occurs after Run starts this deferred join.
func (s *Server) reapRunning() {
	s.mu.Lock()
	entries := make([]*execution, 0, len(s.running))
	for _, entry := range s.running {
		entries = append(entries, entry)
	}
	s.mu.Unlock()
	for _, entry := range entries {
		entry.exec.Cancel()
	}
	for _, entry := range entries {
		<-entry.done
	}
}

// originID mints ids for helper-originated frames (hello). Odd ids
// avoid colliding with broker-originated even ids only by convention;
// correlation is by echoing the peer's id, so collisions are harmless.
func (s *Server) originID() uint64 {
	s.nextID++
	return s.nextID
}

// ReadBasePolicy loads the fd-3 policy for server mode. Required: the
// spec's first duty for the binary is a strict parse of fd 3; failure
// is an error exit before any frame is exchanged.
func ReadBasePolicy() (policy.Policy, error) {
	f := os.NewFile(3, "policy")
	if f == nil {
		return policy.Policy{}, fmt.Errorf("server: fd 3 (policy) not open")
	}
	defer f.Close()
	return policy.ReadFrom(f)
}
