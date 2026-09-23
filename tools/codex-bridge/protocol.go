package main

import (
	"encoding/binary"
	"encoding/json"
	"errors"
	"io"
	"sync"
)

const maxFrame = 4 << 20

// command is a versioned request from Loom. Authentication data is absent:
// the helper alone owns its credential profile.
type command struct {
	V       int    `json:"v"`
	ID      string `json:"id"`
	Cmd     string `json:"cmd"`
	Profile string `json:"profile"`
	BodyB64 string `json:"body_b64,omitempty"`
}

// event is a versioned response. Data carries inference bytes, never tokens.
type event struct {
	V        int          `json:"v"`
	ID       string       `json:"id,omitempty"`
	Event    string       `json:"event"`
	Status   int          `json:"status,omitempty"`
	DataB64  string       `json:"data_b64,omitempty"`
	Code     string       `json:"code,omitempty"`
	URL      string       `json:"url,omitempty"`
	UserCode string       `json:"user_code,omitempty"`
	Plan     string       `json:"plan,omitempty"`
	Models   *[]modelInfo `json:"models,omitempty"`
}

type modelInfo struct {
	ID              string   `json:"id"`
	ContextWindow   int      `json:"context_window,omitempty"`
	ReasoningLevels []string `json:"reasoning_levels,omitempty"`
}

func readFrame(r io.Reader) (command, error) {
	var length [4]byte
	if _, err := io.ReadFull(r, length[:]); err != nil {
		return command{}, err
	}
	n := binary.BigEndian.Uint32(length[:])
	if n == 0 || n > maxFrame {
		return command{}, errors.New("invalid frame length")
	}
	buf := make([]byte, n)
	if _, err := io.ReadFull(r, buf); err != nil {
		return command{}, err
	}
	var c command
	if err := json.Unmarshal(buf, &c); err != nil {
		return command{}, errors.New("invalid frame JSON")
	}
	return c, nil
}

type frameWriter struct {
	mu sync.Mutex
	w  io.Writer
}

func (f *frameWriter) send(e event) error {
	e.V = 1
	buf, err := json.Marshal(e)
	if err != nil || len(buf) > maxFrame {
		return errors.New("invalid output frame")
	}
	var length [4]byte
	binary.BigEndian.PutUint32(length[:], uint32(len(buf)))
	f.mu.Lock()
	defer f.mu.Unlock()
	if err := writeAll(f.w, length[:]); err != nil {
		return err
	}
	return writeAll(f.w, buf)
}

func writeAll(w io.Writer, buf []byte) error {
	for len(buf) > 0 {
		n, err := w.Write(buf)
		if err != nil {
			return err
		}
		if n == 0 {
			return io.ErrShortWrite
		}
		buf = buf[n:]
	}
	return nil
}
