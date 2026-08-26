// Package server implements the helper's side of the effect-plane
// protocol: frames in on stdin, frames out on stdout, one execution at
// a time.
//
// One-exec-at-a-time is deliberate: the broker's ExecPool owns
// concurrency by running more helpers, which keeps "the pgroup" in the
// cancel contract unambiguous (cancel → SIGTERM the pgroup → SIGKILL
// within 2s → the broker's own escalation kills the whole helper).
package server

import (
	"fmt"
	"io"
	"os"

	"github.com/roasbeef/loom/sandbox/internal/framing"
	"github.com/roasbeef/loom/sandbox/internal/jail"
	"github.com/roasbeef/loom/sandbox/internal/policy"
)

// Server drives the protocol loop.
type Server struct {
	conn     *framing.Conn
	feat     jail.Features
	selfExe  string
	basePol  policy.Policy
	nextID   uint64 // ids for frames the helper originates
	running  *jail.Exec
	waitDone chan struct{}
}

// New builds a server. basePol is the fd-3 policy: the default for
// exec_start frames that omit their own.
func New(conn *framing.Conn, feat jail.Features, selfExe string, basePol policy.Policy) *Server {
	return &Server{conn: conn, feat: feat, selfExe: selfExe, basePol: basePol}
}

// Run performs the hello exchange and serves frames until the peer
// closes the channel or a protocol violation forces us to. Per spec
// §3.3.6 a malformed frame closes the channel (after an error frame so
// the broker can settle the effect in-band).
func (s *Server) Run() error {
	// The helper introduces itself first: the broker learns the honest
	// feature set before it commits any work to us.
	if err := s.conn.Write(s.originID(), framing.KindHello, framing.Hello{
		Proto:    framing.ProtoVersion,
		Peer:     "exec-helper",
		Features: s.feat.List(),
	}); err != nil {
		return err
	}

	helloSeen := false
	for {
		f, err := s.conn.Read()
		if err == io.EOF {
			s.reapRunning()
			return nil
		}
		if err != nil {
			// Malformed frame: report in-band, then close.
			_ = s.conn.WriteError(0, framing.ErrCodeMalformed, err.Error())
			s.reapRunning()
			return fmt.Errorf("server: malformed frame: %w", err)
		}

		if !helloSeen && f.Kind != framing.KindHello {
			_ = s.conn.WriteError(f.ID, framing.ErrCodeProto, "expected hello before "+f.Kind)
			s.reapRunning()
			return fmt.Errorf("server: %s before hello", f.Kind)
		}

		switch f.Kind {
		case framing.KindHello:
			var h framing.Hello
			if err := framing.DecodeBody(f.Body, &h); err != nil {
				_ = s.conn.WriteError(f.ID, framing.ErrCodeMalformed, err.Error())
				return err
			}
			if h.Proto != framing.ProtoVersion {
				_ = s.conn.WriteError(f.ID, framing.ErrCodeProto,
					fmt.Sprintf("unsupported proto %d", h.Proto))
				s.reapRunning()
				return fmt.Errorf("server: proto mismatch %d", h.Proto)
			}
			helloSeen = true

		case framing.KindHeartbeat:
			_ = s.conn.Write(f.ID, framing.KindHeartbeat, map[string]any{})

		case framing.KindExecStart:
			s.handleExecStart(f)

		case framing.KindExecStdin:
			s.handleExecStdin(f)

		case framing.KindCancel:
			// Idempotent by contract: with no (or an already-finished)
			// execution there is nothing to do and no error to raise.
			if s.running != nil {
				s.running.Cancel()
			}

		default:
			// Unknown kind: unlike a malformed frame this parses fine,
			// so answer in-band and keep the channel; the broker may be
			// newer than us and able to downgrade.
			_ = s.conn.WriteError(f.ID, framing.ErrCodeUnknownKind, f.Kind)
		}
	}
}

func (s *Server) handleExecStart(f framing.Frame) {
	if s.running != nil {
		select {
		case <-s.waitDone:
			s.running = nil
		default:
			_ = s.conn.WriteError(f.ID, framing.ErrCodeBusy, "an execution is already running")
			return
		}
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

	s.running = ex
	done := make(chan struct{})
	s.waitDone = done
	go func() {
		res := ex.Wait()
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
		close(done)
	}()
}

func (s *Server) handleExecStdin(f framing.Frame) {
	if s.running == nil {
		_ = s.conn.WriteError(f.ID, framing.ErrCodeNoExec, "no execution running")
		return
	}
	var body framing.ExecStdin
	if err := framing.DecodeBody(f.Body, &body); err != nil {
		_ = s.conn.WriteError(f.ID, framing.ErrCodeMalformed, err.Error())
		return
	}
	if err := s.running.WriteStdin(body.Data, body.EOF); err != nil {
		_ = s.conn.WriteError(f.ID, framing.ErrCodeNoExec, err.Error())
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

// reapRunning kills and joins any in-flight execution when the channel
// dies: a helper whose broker is gone must leave no jail behind.
func (s *Server) reapRunning() {
	if s.running == nil {
		return
	}
	s.running.Cancel()
	<-s.waitDone
	s.running = nil
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
