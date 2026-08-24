package framing

import (
	"bytes"
	"encoding/binary"
	"io"
	"reflect"
	"testing"
)

func TestRoundtripAllKinds(t *testing.T) {
	cases := []struct {
		kind string
		body any
	}{
		{KindHello, Hello{Proto: 1, Peer: "exec-helper", Features: []string{"bwrap", "landlock"}}},
		{KindExecStdin, ExecStdin{Data: []byte("input\n"), EOF: true}},
		{KindExecOut, ExecOut{Stream: "stdout", Data: []byte("chunk"), Bytes: 5, Truncated: false}},
		{KindExecExit, ExecExit{Code: 3, StdoutBytes: 10, Enforcement: []string{"bwrap"}, WallMs: 42}},
		{KindCancel, map[string]any{}},
		{KindHeartbeat, map[string]any{}},
		{KindError, ErrorBody{Code: ErrCodeBusy, Msg: "an execution is already running"}},
	}
	for _, tc := range cases {
		t.Run(tc.kind, func(t *testing.T) {
			var buf bytes.Buffer
			conn := NewConn(&buf, &buf)
			if err := conn.Write(7, tc.kind, tc.body); err != nil {
				t.Fatalf("Write: %v", err)
			}
			f, err := conn.Read()
			if err != nil {
				t.Fatalf("Read: %v", err)
			}
			if f.V != ProtoVersion || f.ID != 7 || f.Kind != tc.kind {
				t.Fatalf("envelope mismatch: %+v", f)
			}
			// Decode the body back into a fresh value of the same type
			// and compare where the type is a struct.
			switch want := tc.body.(type) {
			case Hello:
				var got Hello
				if err := DecodeBody(f.Body, &got); err != nil {
					t.Fatalf("DecodeBody: %v", err)
				}
				if !reflect.DeepEqual(got, want) {
					t.Fatalf("body mismatch: got %+v want %+v", got, want)
				}
			case ExecOut:
				var got ExecOut
				if err := DecodeBody(f.Body, &got); err != nil {
					t.Fatalf("DecodeBody: %v", err)
				}
				if !reflect.DeepEqual(got, want) {
					t.Fatalf("body mismatch: got %+v want %+v", got, want)
				}
			}
		})
	}
}

func TestExecStartBodyRoundtrip(t *testing.T) {
	body := ExecStart{
		Argv:  []string{"/bin/sh", "-c", "echo hi"},
		Env:   map[string]string{"PATH": "/bin"},
		Cwd:   "/work",
		Token: bytes.Repeat([]byte{0xAA}, 32),
	}
	raw, err := MarshalBody(body)
	if err != nil {
		t.Fatalf("MarshalBody: %v", err)
	}
	var got ExecStart
	if err := DecodeBody(raw, &got); err != nil {
		t.Fatalf("DecodeBody: %v", err)
	}
	if !reflect.DeepEqual(got.Argv, body.Argv) || got.Cwd != body.Cwd ||
		!bytes.Equal(got.Token, body.Token) || got.Env["PATH"] != "/bin" {
		t.Fatalf("mismatch: %+v", got)
	}
}

func TestDecodeBodyRejectsUnknownFields(t *testing.T) {
	raw, err := MarshalBody(map[string]any{"proto": 1, "peer": "x", "features": []any{}, "sneaky": true})
	if err != nil {
		t.Fatal(err)
	}
	var h Hello
	if err := DecodeBody(raw, &h); err == nil {
		t.Fatal("unknown body field accepted")
	}
}

func TestReadFrameLengthCap(t *testing.T) {
	var buf bytes.Buffer
	var lenBuf [4]byte
	binary.BigEndian.PutUint32(lenBuf[:], MaxFrameLen+1)
	buf.Write(lenBuf[:])
	if _, err := ReadFrame(&buf); err != ErrFrameTooLarge {
		t.Fatalf("want ErrFrameTooLarge, got %v", err)
	}
}

func TestReadFrameCleanEOF(t *testing.T) {
	if _, err := ReadFrame(bytes.NewReader(nil)); err != io.EOF {
		t.Fatalf("want io.EOF, got %v", err)
	}
}

func TestReadFramePartial(t *testing.T) {
	// A length prefix promising more bytes than follow.
	var buf bytes.Buffer
	var lenBuf [4]byte
	binary.BigEndian.PutUint32(lenBuf[:], 100)
	buf.Write(lenBuf[:])
	buf.WriteString("short")
	if _, err := ReadFrame(&buf); err == nil || err == io.EOF {
		t.Fatalf("partial frame must be an explicit error, got %v", err)
	}
}

// corpus returns malformed payloads that must all decode to errors
// without panicking. Shared between the table test and the fuzz seeds.
func corpus(t *testing.T) [][]byte {
	valid, err := EncodeFrame(Frame{V: 1, ID: 1, Kind: KindHeartbeat, Body: mustBody(t, map[string]any{})})
	if err != nil {
		t.Fatal(err)
	}
	payload := valid[4:]
	return [][]byte{
		{},                       // empty
		{0xc0},                   // nil
		{0x90},                   // empty array
		{0x80},                   // empty map: all keys missing
		payload[:len(payload)-1], // truncated valid frame
		append(append([]byte{}, payload...), 0x01), // trailing byte
		{0x81, 0xa1, 0x76, 0x02},                   // {v:2}
		{0x81, 0xa1, 0x76, 0xa1, 0x31},             // {v:"1"}
		{0xde, 0xad, 0xbe, 0xef},                   // junk
		{0x81, 0xa4, 0x6b, 0x69, 0x6e, 0x64, 0xc0}, // {kind:nil}
		bytes.Repeat([]byte{0xdc}, 32),             // nested truncated arrays
	}
}

func mustBody(t *testing.T, v any) []byte {
	t.Helper()
	b, err := MarshalBody(v)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

func TestDecodePayloadMalformedNeverPanics(t *testing.T) {
	for i, raw := range corpus(t) {
		if _, err := DecodePayload(raw); err == nil {
			t.Errorf("corpus[%d]: malformed payload accepted", i)
		}
	}
}

// FuzzDecodePayload runs the seed corpus on every `go test` run and
// digs deeper under `go test -fuzz`. The property is total decoding:
// any byte string yields a value or an error, never a panic.
func FuzzDecodePayload(f *testing.F) {
	valid, err := EncodeFrame(Frame{V: 1, ID: 9, Kind: KindExecOut,
		Body: mustFuzzBody(f, ExecOut{Stream: "stdout", Data: []byte("x"), Bytes: 1})})
	if err != nil {
		f.Fatal(err)
	}
	f.Add(valid[4:])
	f.Add([]byte{})
	f.Add([]byte{0x80})
	f.Add([]byte{0x81, 0xa1, 0x76, 0x01})
	f.Add(bytes.Repeat([]byte{0xde}, 64))
	f.Fuzz(func(t *testing.T, data []byte) {
		f, err := DecodePayload(data)
		if err == nil && f.Kind == "" {
			t.Fatal("accepted frame with empty kind")
		}
	})
}

func mustFuzzBody(f *testing.F, v any) []byte {
	b, err := MarshalBody(v)
	if err != nil {
		f.Fatal(err)
	}
	return b
}

// FuzzReadFrame covers the length-prefixed path end to end.
func FuzzReadFrame(f *testing.F) {
	valid, _ := EncodeFrame(Frame{V: 1, ID: 2, Kind: KindHeartbeat, Body: []byte{0x80}})
	f.Add(valid)
	f.Add([]byte{0, 0, 0, 0})
	f.Add([]byte{0xff, 0xff, 0xff, 0xff})
	f.Add([]byte{0, 0, 0, 5, 1, 2})
	f.Fuzz(func(t *testing.T, data []byte) {
		_, _ = ReadFrame(bytes.NewReader(data)) // must not panic
	})
}
