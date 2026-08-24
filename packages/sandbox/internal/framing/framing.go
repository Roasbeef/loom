// Package framing implements the effect-plane wire protocol from the
// implementation spec, Part 1.4 (frozen):
//
//	frame    := u32_be length ++ msgpack(map)
//	map keys := "v":1, "id":u64, "kind":str, "body":map
//
// Every inbound frame is parsed and validated as data (two-channel
// doctrine, design §5.6): a malformed frame is an error result, never a
// panic, and per spec §3.3.6 the caller closes the channel on one.
package framing

import (
	"bytes"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"sync"

	"github.com/vmihailenco/msgpack/v5"
)

// ProtoVersion is the frame/hello protocol version this helper speaks.
const ProtoVersion = 1

// MaxFrameLen caps a frame's payload. The helper's own frames are small
// (output is chunked well below this); the cap exists so a corrupt or
// hostile length prefix cannot make us allocate gigabytes.
const MaxFrameLen = 1 << 24 // 16 MiB

// Frame kinds implemented by the exec helper. cap_call/cap_result exist
// in the shared protocol but are satellite-facing; the helper rejects
// them like any other unknown kind.
const (
	KindHello     = "hello"
	KindExecStart = "exec_start"
	KindExecStdin = "exec_stdin"
	KindExecOut   = "exec_out"
	KindExecExit  = "exec_exit"
	KindCancel    = "cancel"
	KindHeartbeat = "heartbeat"
	KindError     = "error"
)

// ErrFrameTooLarge is returned when a length prefix exceeds MaxFrameLen.
var ErrFrameTooLarge = errors.New("framing: frame exceeds maximum length")

// Frame is the envelope shared by every message.
type Frame struct {
	V    int                `msgpack:"v"`
	ID   uint64             `msgpack:"id"`
	Kind string             `msgpack:"kind"`
	Body msgpack.RawMessage `msgpack:"body"`
}

// Hello is the handshake body: {proto, peer, features}.
type Hello struct {
	Proto    int      `msgpack:"proto"`
	Peer     string   `msgpack:"peer"`
	Features []string `msgpack:"features"`
}

// ExecStart is the body of exec_start. Policy is kept raw so the strict
// policy decoder owns its validation; Limits, when non-nil, overrides
// policy.limits for this execution (the spec lists both; we treat the
// outer one as the per-exec override).
type ExecStart struct {
	Argv   []string           `msgpack:"argv"`
	Env    map[string]string  `msgpack:"env"`
	Cwd    string             `msgpack:"cwd"`
	Policy msgpack.RawMessage `msgpack:"policy"`
	Token  []byte             `msgpack:"token"`
	Limits msgpack.RawMessage `msgpack:"limits"`
}

// ExecStdin carries a chunk of stdin for the running execution. EOF true
// closes the child's stdin after any data in this frame is written.
type ExecStdin struct {
	Data []byte `msgpack:"data"`
	EOF  bool   `msgpack:"eof"`
}

// ExecOut is one chunk of child output. Bytes is the cumulative count
// for the stream *including* this chunk, so the broker can verify it
// lost nothing. Truncated marks the single final chunk emitted when the
// per-stream output_bytes cap is hit; after it, the stream stays silent
// while the helper keeps draining the child (discarding) so the child
// never blocks on a full pipe.
type ExecOut struct {
	Stream    string `msgpack:"stream"` // "stdout" | "stderr"
	Data      []byte `msgpack:"data"`
	Bytes     uint64 `msgpack:"bytes"`
	Truncated bool   `msgpack:"truncated"`
}

// ExecExit reports the completed execution. Enforcement lists what was
// actually applied around the child (e.g. "bwrap", "landlock:abi=5",
// "seccomp-net", "rlimit-cpu"); Degraded is true when bwrap was
// unavailable so only in-process layers ran — the broker may refuse such
// results by policy.
type ExecExit struct {
	Code            int      `msgpack:"code"`
	Signal          int      `msgpack:"signal"` // 0 when exited normally
	StdoutBytes     uint64   `msgpack:"stdout_bytes"`
	StderrBytes     uint64   `msgpack:"stderr_bytes"`
	StdoutTruncated bool     `msgpack:"stdout_truncated"`
	StderrTruncated bool     `msgpack:"stderr_truncated"`
	Enforcement     []string `msgpack:"enforcement"`
	Degraded        bool     `msgpack:"degraded"`
	WallMs          uint64   `msgpack:"wall_ms"`
	TimedOut        bool     `msgpack:"timed_out"`
}

// ErrorBody is the body of an error frame.
type ErrorBody struct {
	Code string `msgpack:"code"`
	Msg  string `msgpack:"msg"`
}

// Error codes used by the helper.
const (
	ErrCodeMalformed   = "malformed_frame"
	ErrCodeBadPolicy   = "bad_policy"
	ErrCodeBusy        = "busy"
	ErrCodeNoExec      = "no_exec"
	ErrCodeSpawn       = "spawn_failed"
	ErrCodeUnknownKind = "unknown_kind"
	ErrCodeProto       = "proto_mismatch"
)

// EncodeFrame serializes a frame with its length prefix.
func EncodeFrame(f Frame) ([]byte, error) {
	payload, err := msgpack.Marshal(&f)
	if err != nil {
		return nil, fmt.Errorf("framing: encode: %w", err)
	}
	if len(payload) > MaxFrameLen {
		return nil, ErrFrameTooLarge
	}
	out := make([]byte, 4+len(payload))
	binary.BigEndian.PutUint32(out[:4], uint32(len(payload)))
	copy(out[4:], payload)
	return out, nil
}

// ReadFrame reads exactly one frame. io.EOF (clean close between frames)
// is returned as-is; a partial frame becomes io.ErrUnexpectedEOF. Any
// structural problem in the payload is an error, never a panic.
func ReadFrame(r io.Reader) (Frame, error) {
	var lenBuf [4]byte
	if _, err := io.ReadFull(r, lenBuf[:]); err != nil {
		if errors.Is(err, io.EOF) {
			return Frame{}, io.EOF
		}
		return Frame{}, fmt.Errorf("framing: read length: %w", err)
	}
	n := binary.BigEndian.Uint32(lenBuf[:])
	if n > MaxFrameLen {
		return Frame{}, ErrFrameTooLarge
	}
	payload := make([]byte, n)
	if _, err := io.ReadFull(r, payload); err != nil {
		return Frame{}, fmt.Errorf("framing: read payload: %w", err)
	}
	return DecodePayload(payload)
}

// DecodePayload parses the msgpack envelope of one frame (without the
// length prefix) and validates {v, id, kind, body}.
func DecodePayload(payload []byte) (Frame, error) {
	var f Frame
	dec := msgpack.NewDecoder(bytes.NewReader(payload))
	dec.DisallowUnknownFields(true)
	if err := dec.Decode(&f); err != nil {
		return Frame{}, fmt.Errorf("framing: decode envelope: %w", err)
	}
	if _, err := dec.PeekCode(); err != io.EOF {
		return Frame{}, fmt.Errorf("framing: trailing bytes after frame map")
	}
	if f.V != ProtoVersion {
		return Frame{}, fmt.Errorf("framing: unsupported frame version %d", f.V)
	}
	if f.Kind == "" {
		return Frame{}, fmt.Errorf("framing: missing kind")
	}
	if len(f.Body) == 0 {
		return Frame{}, fmt.Errorf("framing: missing body")
	}
	return f, nil
}

// DecodeBody strictly decodes a frame body into the kind's struct,
// rejecting unknown fields — an option we do not understand could be a
// restriction we would silently not honor.
func DecodeBody(body msgpack.RawMessage, into any) error {
	dec := msgpack.NewDecoder(bytes.NewReader(body))
	dec.DisallowUnknownFields(true)
	if err := dec.Decode(into); err != nil {
		return fmt.Errorf("framing: decode body: %w", err)
	}
	return nil
}

// MarshalBody serializes a typed body for a frame.
func MarshalBody(v any) (msgpack.RawMessage, error) {
	b, err := msgpack.Marshal(v)
	if err != nil {
		return nil, fmt.Errorf("framing: encode body: %w", err)
	}
	return b, nil
}

// Conn is a frame reader/writer over a stream pair. Writes are
// mutex-serialized because output-pump goroutines and the main loop both
// emit frames; interleaving two frames' bytes would corrupt the channel.
type Conn struct {
	r  io.Reader
	w  io.Writer
	mu sync.Mutex
}

// NewConn builds a Conn over the given reader and writer.
func NewConn(r io.Reader, w io.Writer) *Conn { return &Conn{r: r, w: w} }

// Read reads the next frame.
func (c *Conn) Read() (Frame, error) { return ReadFrame(c.r) }

// Write encodes and writes one frame atomically with respect to other
// Write calls.
func (c *Conn) Write(id uint64, kind string, body any) error {
	raw, err := MarshalBody(body)
	if err != nil {
		return err
	}
	buf, err := EncodeFrame(Frame{V: ProtoVersion, ID: id, Kind: kind, Body: raw})
	if err != nil {
		return err
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	if _, err := c.w.Write(buf); err != nil {
		return fmt.Errorf("framing: write: %w", err)
	}
	return nil
}

// WriteError emits an error frame correlated to id.
func (c *Conn) WriteError(id uint64, code, msg string) error {
	return c.Write(id, KindError, ErrorBody{Code: code, Msg: msg})
}
