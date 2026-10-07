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
	conn               *framing.Conn
	feat               jail.Features
	selfExe            string
	basePol            policy.Policy
	protocolNegotiated bool
	protocol           *protocolRun
	creditWriter       *creditWriter

	nextID  uint64 // ids for frames the helper originates
	running *jail.Exec

	// execFreed is closed as soon as the running execution's Wait has
	// returned, before its exec_exit frame is written. It answers
	// "is the helper free to start another execution".
	execFreed chan struct{}

	// waitDone is closed after that exec_exit frame has been written and
	// the execution's cgroup removed, and not before the previous
	// execution's waitDone. It answers "has the terminal frame reached the
	// channel", which is the weaker moment reapRunning must not exit
	// before.
	waitDone chan struct{}
}

// New builds a server. basePol is the fd-3 policy: the default for
// exec_start frames that omit their own.
func New(conn *framing.Conn, feat jail.Features, selfExe string, basePol policy.Policy) *Server {
	return &Server{conn: conn, feat: feat, selfExe: selfExe, basePol: basePol}
}

// Run performs the hello exchange and serves frames until the peer
// requests shutdown, closes the channel, or a protocol violation forces us
// to stop. Every return joins the current jail before the helper exits.
// Per spec §3.3.6 a malformed frame closes the channel (after an error
// frame so the broker can settle the effect in-band).
func (s *Server) Run() error {
	// A native exit can witness retirement only after the execution's Wait
	// completes. Keep this obligation on every return, including malformed
	// traffic during an execution, rather than on selected dispatch branches.
	defer func() {
		s.reapRunning()
		if s.creditWriter != nil {
			s.creditWriter.abort()
			<-s.creditWriter.done
		}
	}()

	// The helper introduces itself first: the broker learns the honest
	// feature set before it commits any work to us.
	if err := s.conn.Write(s.originID(), framing.KindHello, framing.Hello{
		Proto:    framing.ExecProtocolVersion,
		Peer:     "exec-helper",
		Features: append(s.feat.List(), framing.ProtocolCreditFeature),
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
			_ = s.writeError(0, framing.ErrCodeMalformed, err.Error())
			return fmt.Errorf("server: malformed frame: %w", err)
		}

		if !helloSeen && f.Kind != framing.KindHello {
			_ = s.writeError(f.ID, framing.ErrCodeProto, "expected hello before "+f.Kind)
			return fmt.Errorf("server: %s before hello", f.Kind)
		}

		switch f.Kind {
		case framing.KindHello:
			var h framing.Hello
			if err := framing.DecodeBody(f.Body, &h); err != nil {
				_ = s.writeError(f.ID, framing.ErrCodeMalformed, err.Error())
				return err
			}
			// Name both numbers, not just the peer's. A helper and a
			// broker built from different trees is the failure this
			// check exists for, and "unsupported proto 1" alone leaves
			// the reader to guess what this binary wanted.
			if h.Proto != framing.ExecProtocolVersion {
				_ = s.writeError(f.ID, framing.ErrCodeProto,
					fmt.Sprintf("peer speaks exec protocol %d; this helper speaks %d",
						h.Proto, framing.ExecProtocolVersion))
				return fmt.Errorf("server: exec protocol mismatch: peer %d, helper %d",
					h.Proto, framing.ExecProtocolVersion)
			}
			helloSeen = true
			for _, feature := range h.Features {
				if feature == framing.ProtocolCreditFeature {
					s.protocolNegotiated = true
				}
			}

		case framing.KindHeartbeat:
			if s.creditWriter != nil {
				_, _ = s.creditWriter.offer(creditControl, f.ID, framing.KindHeartbeat, map[string]any{})
				continue
			}
			_ = s.conn.Write(f.ID, framing.KindHeartbeat, map[string]any{})

		case framing.KindProtocolStart:
			s.handleProtocolStart(f)
		case framing.KindProtocolInput:
			if s.protocol != nil {
				s.protocol.input(f)
			} else {
				s.protocolError(f.ID, "no credited execution")
			}
		case framing.KindProtocolOutputConsumed:
			if s.protocol != nil {
				s.protocol.consume(f)
			} else {
				s.protocolError(f.ID, "no credited execution")
			}
		case framing.KindExecStart:
			s.handleExecStart(f)

		case framing.KindExecStdin:
			s.handleExecStdin(f)

		case framing.KindCancel:
			// Idempotent by contract: with no (or an already-finished)
			// execution there is nothing to do and no error to raise.
			if s.running != nil {
				if s.protocol != nil {
					s.protocol.fail()
				}
				s.running.Cancel()
			}

		case framing.KindShutdown:
			var body map[string]any
			if err := framing.DecodeBody(f.Body, &body); err != nil || body == nil || len(body) != 0 {
				_ = s.writeError(f.ID, framing.ErrCodeMalformed, "shutdown: expected empty map")
				return fmt.Errorf("server: shutdown requires an empty map")
			}

			// Stop dispatch before cancellation. The deferred join emits the
			// running execution's terminal frame, then allows native exit.
			// Stdin stays open so the broker can retain its exit-status witness;
			// neither a reply frame nor port closure is that witness.
			return nil

		default:
			// Unknown kind: unlike a malformed frame this parses fine,
			// so answer in-band and keep the channel; the broker may be
			// newer than us and able to downgrade.
			_ = s.writeError(f.ID, framing.ErrCodeUnknownKind, f.Kind)
		}
	}
}

func (s *Server) handleExecStart(f framing.Frame) {
	if s.protocol != nil {
		if s.protocol.mode == framing.ProtocolServer {
			s.protocolError(f.ID, "server execution requires exact helper retirement")
			return
		}
		select {
		case <-s.waitDone:
			s.protocol = nil
		default:
			s.protocolError(f.ID, "original execution has not joined")
			return
		}
	}
	// Busy is decided by the child, not by the frame that reports it.
	// execFreed closes when Wait returns, which is strictly before the
	// exec_exit write; consulting waitDone here instead made a broker
	// that dispatched the moment it read exec_exit race the helper's own
	// close and get a spurious busy refusal for a sequential caller.
	if s.running != nil {
		select {
		case <-s.execFreed:
			s.running = nil
		default:
			_ = s.writeError(f.ID, framing.ErrCodeBusy, "an execution is already running")
			return
		}
	}

	var body framing.ExecStart
	if err := framing.DecodeBody(f.Body, &body); err != nil {
		_ = s.writeError(f.ID, framing.ErrCodeMalformed, err.Error())
		return
	}
	if len(body.Argv) == 0 {
		_ = s.writeError(f.ID, framing.ErrCodeMalformed, "exec_start: empty argv")
		return
	}
	if len(body.Token) == 0 {
		_ = s.writeError(f.ID, framing.ErrCodeMalformed, "exec_start: missing token")
		return
	}

	pol := s.basePol
	if len(body.Policy) > 0 {
		p, err := policy.Decode(body.Policy)
		if err != nil {
			_ = s.writeError(f.ID, framing.ErrCodeBadPolicy, err.Error())
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
		_ = s.writeError(f.ID, framing.ErrCodeSpawn, err.Error())
		return
	}

	s.running = ex

	// Two signals, closed either side of the terminal write. Freeing
	// before the write is what makes a strictly sequential broker
	// sequential: it reads exec_exit and dispatches the next
	// exec_start, and by then the child has long been reaped. Signalling
	// only after the write leaves a window in which the helper is idle
	// and still calls itself busy.
	//
	// Nothing is lost by freeing early. Settle joins the output pumps, so
	// no further exec_out can be emitted for this id, and the one frame
	// still owed carries this execution's id, which is not the next
	// one's. Conn.Write is mutex-serialized and emits a frame in a
	// single Write, so that frame cannot interleave with the next
	// execution's bytes even if a broker dispatched without waiting for
	// it.
	//
	// The cgroup's removal follows the frame, because it waits out the
	// jail's namespace teardown and a broker reading exec_exit has no use
	// for that wait. It still precedes done, and
	// each execution's done also waits for the previous one's, so the
	// join in reapRunning covers every removal still in flight, not only
	// the current execution's.
	freed := make(chan struct{})
	done := make(chan struct{})
	previous := s.waitDone
	s.execFreed = freed
	s.waitDone = done
	go func() {
		res, release := ex.Settle()
		close(freed)
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
		release()
		if previous != nil {
			<-previous
		}
		close(done)
	}()
}

// handleExecStdin queues a chunk; it does not write the child's pipe. It
// runs on the frame loop, which must keep reading cancel, heartbeat and
// shutdown whatever the payload does with its stdin, so Exec.WriteStdin only
// hands the bytes to the execution's writer goroutine (jail/stdin.go).
// Waiting here is possible only when jail.StdinPendingMax bytes are already
// queued for a payload that is not reading, and the wall deadline and the
// execution's end both still bound it.
func (s *Server) handleExecStdin(f framing.Frame) {
	if s.protocol != nil {
		s.protocol.fence()
		return
	}
	if s.running == nil {
		_ = s.writeError(f.ID, framing.ErrCodeNoExec, "no execution running")
		return
	}
	var body framing.ExecStdin
	if err := framing.DecodeBody(f.Body, &body); err != nil {
		_ = s.writeError(f.ID, framing.ErrCodeMalformed, err.Error())
		return
	}
	if err := s.running.WriteStdin(body.Data, body.EOF); err != nil {
		_ = s.writeError(f.ID, framing.ErrCodeNoExec, err.Error())
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

// reapRunning cancels and joins any in-flight execution before server exit.
// Joining proves completion of the jail runner's existing cleanup, not a
// stronger descendant-containment guarantee than the platform provides.
//
// This waits on waitDone rather than execFreed, and the difference is the
// whole point of keeping two signals: the shutdown witness the broker
// relies on is that the terminal frame reached the channel before native
// exit, and only waitDone says that. It joins the *current* execution,
// which is enough even in the out-of-contract case where a broker started
// a second execution while the first exit frame was still being written:
// that write holds the connection mutex, so the second execution's own
// exit frame cannot have been written until the first one was.
func (s *Server) reapRunning() {
	if s.running == nil {
		return
	}
	if s.protocol != nil {
		s.protocol.fail()
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

// writeError keeps malformed credited traffic off the blocking writer path.
func (s *Server) writeError(id uint64, code, message string) error {
	if s.creditWriter == nil {
		return s.conn.WriteError(id, code, message)
	}
	if len(message) > 64 {
		message = message[:64]
	}
	_, ok := s.creditWriter.offer(creditControl, id, framing.KindError, framing.ErrorBody{Code: code, Msg: message})
	if !ok {
		return fmt.Errorf("credited error slot unavailable")
	}
	return nil
}
